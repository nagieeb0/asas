defmodule Asas.Moyasar do
  @moduledoc """
  The Moyasar HTTP client. **Never run against a real merchant account.**

  Everything here is written from the live documentation read on 2026-08-20:

      https://docs.moyasar.com/api/api-introduction     base URL, HTTP Basic
      https://docs.moyasar.com/api/authentication       pk_ vs sk_, empty password
      https://docs.moyasar.com/api/payments/01-create-payment
      https://docs.moyasar.com/api/payments/02-fetch-payment
      https://docs.moyasar.com/api/invoices/01-create-invoice
      https://docs.moyasar.com/api/other/tokens/create-token
      https://docs.moyasar.com/api/other/webhooks/webhook-reference
      https://docs.moyasar.com/guides/tokenization/tokenized-cards
      https://docs.moyasar.com/guides/payment-operations
      https://docs.moyasar.com/guides/card-payments/test-cards
      https://docs.moyasar.com/api/errors

  It compiles, its request bodies match the documented parameters, and its response
  handling matches the documented shapes. It has never received a byte from
  api.moyasar.com. Treat every `{:ok, …}` below as "the code believes this", not as
  evidence.

      https://api.moyasar.com/v1

  ## Two keys, and only one of them belongs here

      pk_test_… / pk_live_…   PUBLISHABLE. Safe in a browser. Restricted to exactly one
                              operation: create payment. This module never uses it —
                              your own checkout code hands it to the page.

      sk_test_… / sk_live_…   SECRET. Every operation on the account. Server only. If it
                              leaks, regenerate immediately: it can refund, payout and
                              read every payment you have ever taken.

  Authentication is HTTP Basic with the key as the username and **an empty password**:

      curl https://api.moyasar.com/v1/payments -u sk_test_123:

  The trailing colon is the whole of the password. `Req`'s `auth: {:basic, "sk:"}`
  produces exactly that.

  Test mode is not a flag or a header — it is which key you sent. `sk_test_` is sandbox,
  `sk_live_` is real money, and the ONLY thing standing between the two is one
  environment variable. `mode/0` reads the prefix back so a deploy can assert it.

  ## What this module refuses to do

  It never accepts a card number, a CVC or an expiry. Not as an argument, not in a map
  it forwards. Cards reach Moyasar from the customer's browser with the publishable key,
  and the only card-shaped thing that ever exists on this server is a `token_…` string,
  which is useless without our secret key.

  That is also why `create_payment/1` is private and unexported: an exported function
  that takes a `source` map is one careless call site away from a card number in a
  Postgres row, an Oban args column, and a Sentry breadcrumb.

  ## Logging

  `safe/1` is a WHITELIST — `id`, `status`, `amount`, `currency`, `type`, `message`,
  `invoice_id`. A field Moyasar adds tomorrow is invisible by default rather than
  visible by accident, and `number`, `cvc`, `token`, `secret_token` and
  `authorization_code` can never be in the list. No request body is ever logged, at any
  level, on any path.

  ## Retries

  `GET` retries on transient failures. Nothing else does. A retried
  `POST /payments` is a second charge, and a retried `POST /refund` is a second refund;
  Moyasar's `given_id` makes the former idempotent and there is no equivalent for the
  latter. Retrying a charge is therefore the caller's decision, made once, in an Oban
  job that carries the same `given_id` across attempts.
  """

  require Logger

  @default_base_url "https://api.moyasar.com/v1"

  # Moyasar's own timing: a 3-D Secure create can sit while the issuer is consulted.
  @receive_timeout 20_000
  @connect_timeout 10_000

  # The only fields that may appear in a log line. See the moduledoc.
  @loggable ~w(id status amount currency type message invoice_id created_at)

  @typedoc "Why a call failed. Extracted from Raqeemi.Billing, which defined it."
  @type reason :: atom() | {atom(), term()}

  # ── configuration ──────────────────────────────────────────────────────────
  #
  # raqeemi read this from `Raqeemi.Billing.config/0`, i.e. `config :raqeemi,
  # :billing, ...`. Here it follows the same `:asas, :otp_app` convention as every
  # other module in this library, so the host app keeps its own namespace:
  #
  #     config :asas, otp_app: :my_app
  #     config :my_app, Asas.Moyasar, secret_key: System.get_env("MOYASAR_SECRET_KEY")
  #
  # Nothing else about the client changed.
  # The key defaults to this module, but a host that already keeps its gateway
  # settings somewhere else can say so rather than migrate. raqeemi holds
  # `config :raqeemi, :billing` — which also carries `backend`, `paused`,
  # `free_mode`, `prices` and `callback_url`, is read and written by nine test
  # files, and is pinned as a literal string by one of them. Renaming that for a
  # shared HTTP client would be a migration through a money path in exchange for
  # nothing. The library bends instead.
  #
  #     config :asas, otp_app: :raqeemi, moyasar_config_key: :billing
  @doc false
  @spec config() :: keyword()
  def config do
    otp_app = Application.get_env(:asas, :otp_app)
    Application.get_env(otp_app, config_key(), [])
  end

  defp config_key, do: Application.get_env(:asas, :moyasar_config_key, __MODULE__)

  @doc """
  Whether a secret key is present. **False on every machine today.**

      config :my_app, Asas.Moyasar,
        secret_key: System.get_env("MOYASAR_SECRET_KEY"),
        publishable_key: System.get_env("MOYASAR_PUBLISHABLE_KEY"),
        webhook_secret: System.get_env("MOYASAR_WEBHOOK_SECRET")
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, secret_key())

  @doc """
  `:test` or `:live`, read from the key's own prefix, or `{:error, …}`.

  A deploy should assert this. There is no other signal: a `sk_test_` key in production
  serves a working checkout that takes no money, and a `sk_live_` key in staging charges
  a real card for every QA run.
  """
  @spec mode() :: :test | :live | {:error, atom()}
  def mode do
    case secret_key() do
      {:ok, "sk_test_" <> _} -> :test
      {:ok, "sk_live_" <> _} -> :live
      {:ok, _} -> {:error, :unrecognised_key_prefix}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extra `Req` options, merged UNDER ours so nothing here can be overridden.

      config :my_app, Asas.Moyasar, req_options: [plug: {MyMock, []}]

  The merge order is the point: `auth`, `url`, `method` and the timeouts are applied
  after this list, so a config file cannot silently redirect an authenticated request or
  strip its credentials. What it can do is swap the transport, which is how this client
  is tested without a network and how it would sit behind an egress proxy.
  """
  @spec req_options() :: keyword()
  def req_options do
    case Keyword.get(config(), :req_options) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "The API root. Overridable for a mock server; never for a proxy of unknown origin."
  @spec base_url() :: binary()
  def base_url do
    case Keyword.get(config(), :base_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @default_base_url
    end
  end

  # ── invoices: the one-time flow ────────────────────────────────────────────

  @doc """
  `POST /v1/invoices` — a hosted checkout page.

  The response carries `url`, "the checkout page that the merchant must present to the
  payer". Moyasar renders the card form, runs 3-D Secure, and offers whichever methods
  the merchant account has enabled — mada, Visa/Mastercard, Apple Pay, STC Pay — with no
  code here.

  `amount` must be an integer ≥ 100 in the smallest currency unit. `expired_at` should
  always be set; an invoice with no expiry is a standing offer at last year's price.

      {:ok, %{"id" => "…", "status" => "initiated", "url" => "https://…", "amount" => 99_000}}
  """
  @spec create_invoice(map()) :: {:ok, map()} | {:error, reason()}
  def create_invoice(params) when is_map(params) do
    post("/invoices", params, retry: false)
  end

  @doc "`GET /v1/invoices/:id`. Statuses: initiated paid failed refunded canceled on_hold expired voided."
  @spec fetch_invoice(binary()) :: {:ok, map()} | {:error, reason()}
  def fetch_invoice(id) when is_binary(id) do
    with {:ok, id} <- validate_id(id), do: get("/invoices/#{id}")
  end

  # ── payments ───────────────────────────────────────────────────────────────

  @doc """
  `GET /v1/payments/:id`. The authoritative answer to "did this actually get paid".

  Statuses, all eight: `initiated`, `paid`, `authorized`, `failed`, `refunded`,
  `captured`, `voided`, `verified`.

  `initiated` is the 3-D Secure state, not a failure — the cardholder is on his bank's
  OTP page. `authorized` is a hold with `manual: true` and needs a capture within 14
  days on mada. Only `paid` and `captured` mean money moved.
  """
  @spec fetch_payment(binary()) :: {:ok, map()} | {:error, reason()}
  def fetch_payment(id) when is_binary(id) do
    with {:ok, id} <- validate_id(id), do: get("/payments/#{id}")
  end

  @doc """
  `POST /v1/payments` with `source.type = "token"` — the whole of "recurring" at Moyasar.

  There is no subscription resource to renew, so a renewal is an ordinary payment whose
  source happens to be a card we saved. `3ds` defaults to false for token payments
  because the card was authenticated when the token was minted; some issuers still
  soft-decline, and that arrives as a `failed` payment, not an error.

  `params["given_id"]` is a v4 UUID Moyasar treats as an idempotency key. Send the same
  one for every attempt at one billing period.

  The token itself is dropped from every log line this function can produce.
  """
  @spec charge_token(binary(), pos_integer(), map()) ::
          {:ok, map()} | {:error, reason()}
  def charge_token("token_" <> _ = token, amount, params)
      when is_integer(amount) and amount > 0 and is_map(params) do
    source =
      %{"type" => "token", "token" => token}
      |> put_if(params, "3ds")
      |> put_if(params, "manual")
      |> put_if(params, "statement_descriptor")

    body =
      params
      |> Map.drop(["3ds", "manual", "statement_descriptor", "source", "amount"])
      |> Map.put("amount", amount)
      |> Map.put("source", source)
      |> drop_nils()

    post("/payments", body, retry: false)
  end

  def charge_token(_token, amount, _params) when not is_integer(amount) or amount <= 0,
    do: {:error, :bad_amount}

  # Anything that is not a token_ string is refused rather than forwarded — this is the
  # gate that stops a raw PAN being passed in as a "token" by a confused caller.
  def charge_token(_token, _amount, _params), do: {:error, :not_a_card_token}

  @doc """
  `POST /v1/payments/:id/refund`. Full when `amount` is nil, partial otherwise.

  Never retried: there is no idempotency key on refunds and a retried refund is a second
  refund. Allowed from `paid` and `captured` only.

  Moyasar's guidance is to prefer `POST /payments/:id/void` inside the ~2 hour window —
  it reverses instantly and skips the processing fee. That window has always closed by
  the time a contractor asks for his money back, which is why only refund is exposed.
  """
  @spec refund(binary(), pos_integer() | nil) :: {:ok, map()} | {:error, reason()}
  def refund(id, nil) when is_binary(id) do
    with {:ok, id} <- validate_id(id), do: post("/payments/#{id}/refund", %{}, retry: false)
  end

  def refund(id, amount) when is_binary(id) and is_integer(amount) and amount > 0 do
    with {:ok, id} <- validate_id(id),
         do: post("/payments/#{id}/refund", %{"amount" => amount}, retry: false)
  end

  def refund(_, _), do: {:error, :bad_amount}

  # ── tokens ─────────────────────────────────────────────────────────────────

  @doc """
  `GET /v1/tokens/:id` — the saved card's brand, funding, country, expiry and last four.

  Read it to show "mada •••• 1010, expires 12/2030" on the billing page, and to notice
  that a stored card expires before the next renewal. Never store more of it than the
  brand, the last four and the expiry; the token id is the credential and belongs in one
  column, not in a log, a page state or an email.

      {:ok, %{"id" => "token_…", "status" => "active", "brand" => "visa",
              "funding" => "credit", "country" => "SA", "month" => "12",
              "year" => "2030", "last_four" => "1111"}}
  """
  @spec fetch_token(binary()) :: {:ok, map()} | {:error, reason()}
  def fetch_token("token_" <> _ = token) do
    with {:ok, id} <- validate_id(token), do: get("/tokens/#{id}")
  end

  def fetch_token(_), do: {:error, :not_a_card_token}

  # ── webhooks ───────────────────────────────────────────────────────────────

  @doc """
  `POST /v1/webhooks` — registers a delivery endpoint.

  `shared_secret` is what comes back inside every delivery as the body's `secret_token`
  field. It is NOT used to sign anything; see your own webhook verification for what
  that does and does not prove. Generate it with
  `:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)` and put the same
  value in `config :my_app, Asas.Moyasar, webhook_secret:`.

  The ten documented events:

      payment_paid  payment_failed  payment_voided  payment_authorized
      payment_captured  payment_refunded  payment_abandoned  payment_verified
      card_auth_authenticated  card_auth_failed

  Subscribe to `payment_paid` and `payment_failed` and nothing else until a second one
  is actually handled — an event with no handler is an endpoint returning 200 to
  something nobody reads.
  """
  @spec create_webhook(binary(), [binary()], binary()) ::
          {:ok, map()} | {:error, reason()}
  def create_webhook(url, events, shared_secret)
      when is_binary(url) and is_list(events) and is_binary(shared_secret) do
    post(
      "/webhooks",
      %{
        "http_method" => "post",
        "url" => url,
        "shared_secret" => shared_secret,
        "events" => events
      },
      retry: false
    )
  end

  @doc "`GET /v1/webhooks` — what is currently registered."
  @spec list_webhooks() :: {:ok, map()} | {:error, reason()}
  def list_webhooks, do: get("/webhooks")

  # ── logging ────────────────────────────────────────────────────────────────

  @doc """
  A map reduced to the fields that may appear in a log line.

  A whitelist, deliberately: a redaction blacklist has to be updated every time the
  gateway adds a field, and it never is.

      iex> Asas.Moyasar.safe(%{"id" => "p_1", "status" => "paid",
      ...>   "source" => %{"number" => "4111111111111111", "token" => "token_x"}})
      %{"id" => "p_1", "status" => "paid"}
  """
  @spec safe(term()) :: map()
  def safe(map) when is_map(map), do: Map.take(map, @loggable)
  def safe(_), do: %{}

  # ── status predicates and webhook comparison ───────────────────────────────
  #
  # These four are aethel's additions, not raqeemi's. They are the reason the four
  # clients were not a clean subset lattice after all, and they are small enough
  # that carrying them here costs nothing and makes this a true superset.

  @doc """
  Whether money actually moved.

      iex> Asas.Moyasar.paid?(%{"status" => "paid"})
      true
      iex> Asas.Moyasar.paid?(%{"status" => "authorized"})
      false
  """
  @spec paid?(map() | binary() | nil) :: boolean()
  def paid?(%{"status" => status}), do: paid?(status)
  def paid?(status) when is_binary(status), do: status in ~w(paid captured)
  def paid?(_), do: false

  @doc """
  Whether a payment is still in flight — neither paid nor finally failed.

  `initiated` is the one that matters: a customer sitting on their bank's OTP page
  is `initiated`, and treating that as a failure cancels a purchase that is about
  to succeed.
  """
  @spec pending?(map() | binary() | nil) :: boolean()
  def pending?(%{"status" => status}), do: pending?(status)
  def pending?(status) when is_binary(status), do: status in ~w(initiated authorized verified)
  def pending?(_), do: false

  @doc "The configured webhook shared secret, or nil."
  @spec webhook_secret() :: binary() | nil
  def webhook_secret do
    case Keyword.get(config(), :webhook_secret) do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  @doc """
  Constant-time comparison. Anything that is not two binaries is `false` rather
  than an exception — a webhook body with no `secret_token` at all is the
  commonest forgery and must not raise on the hot path.
  """
  @spec secure_compare(term(), term()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash(:sha256, a)
    |> :crypto.exor(:crypto.hash(:sha256, b))
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &Bitwise.bor/2)
    |> Kernel.==(0)
  end

  def secure_compare(_, _), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  defp secret_key do
    case Keyword.get(config(), :secret_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :moyasar_not_configured}
    end
  end

  # An id goes into a URL path. It is Moyasar's own opaque handle, so the whitelist can
  # be tight: a UUID or a `token_…` string, nothing else. This is what stops
  # `fetch_payment("../webhooks")` from reaching a different endpoint entirely, and
  # `fetch_payment("x?foo=1")` from smuggling a query parameter.
  defp validate_id(id) when is_binary(id) and byte_size(id) in 1..128 do
    if id =~ ~r/\A[A-Za-z0-9_-]+\z/, do: {:ok, id}, else: {:error, :invalid_id}
  end

  defp validate_id(_), do: {:error, :invalid_id}

  defp get(path), do: request(:get, path, nil, retry: :safe_transient)

  defp post(path, body, opts), do: request(:post, path, drop_nils(body), opts)

  defp request(method, path, body, opts) do
    with {:ok, key} <- secret_key() do
      options =
        [
          method: method,
          url: base_url() <> path,
          # The empty password IS the documented format: `-u sk_test_123:`.
          auth: {:basic, key <> ":"},
          receive_timeout: @receive_timeout,
          connect_options: [timeout: @connect_timeout],
          # An API that answers with a redirect is not an API we follow.
          redirect: false,
          retry: Keyword.get(opts, :retry, false),
          max_retries: 2,
          # A 4xx is data, not an exception. handle/2 reads the body.
          decode_body: true
        ]
        |> then(fn o -> if is_nil(body), do: o, else: Keyword.put(o, :json, body) end)

      req_options()
      |> Keyword.merge(options)
      |> Req.request()
      |> handle(method, path)
    end
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}, method, path)
       when status in 200..299 and is_map(body) do
    Logger.debug("moyasar: #{method} #{path} #{status} #{inspect(safe(body))}")
    {:ok, body}
  end

  defp handle({:ok, %Req.Response{status: status}}, method, path) when status in 200..299 do
    Logger.warning("moyasar: #{method} #{path} #{status} but body was not a JSON object")
    {:error, :unexpected_response}
  end

  # The documented error shape:
  #   {"type": "invalid_request_error", "message": "Validation Failed",
  #    "errors": {"amount": ["must be an integer"]}}
  #
  # `type` and `message` are Moyasar's own strings and are safe. `errors` is keyed by
  # FIELD NAME, and the field name is the useful part — "source.number is invalid" tells
  # a developer everything without the value ever appearing anywhere.
  defp handle({:ok, %Req.Response{status: status, body: body}}, method, path) do
    type = get_field(body, "type") || http_type(status)
    message = get_field(body, "message") || "HTTP #{status}"
    fields = error_fields(body)

    Logger.warning("moyasar: #{method} #{path} #{status} #{type} fields=#{inspect(fields)}")

    {:error, {:moyasar, status, type, message, fields}}
  end

  defp handle({:error, %{__exception__: true} = exception}, method, path) do
    # Exception.message/1 on a Req/Mint transport error is "connection refused" or
    # "timeout" — no URL, no credentials. Still not interpolating the exception struct,
    # which on some adapters carries the whole request.
    Logger.warning(
      "moyasar: #{method} #{path} transport failure: #{Exception.message(exception)}"
    )

    {:error, :transport_error}
  end

  defp handle(other, method, path) do
    Logger.warning("moyasar: #{method} #{path} unrecognised result #{inspect(elem_type(other))}")
    {:error, :unexpected_response}
  end

  defp elem_type(t) when is_tuple(t) and tuple_size(t) > 0, do: elem(t, 0)
  defp elem_type(_), do: :unknown

  defp get_field(body, key) when is_map(body) do
    case Map.get(body, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp get_field(_, _), do: nil

  defp error_fields(%{"errors" => errors}) when is_map(errors), do: Map.keys(errors)
  defp error_fields(_), do: []

  defp http_type(401), do: "authentication_error"
  defp http_type(403), do: "api_error"
  defp http_type(404), do: "not_found"
  defp http_type(429), do: "rate_limit_error"
  defp http_type(status) when status >= 500, do: "api_error"
  defp http_type(_), do: "invalid_request_error"

  defp put_if(source, params, key) do
    case Map.fetch(params, key) do
      {:ok, nil} -> source
      {:ok, value} -> Map.put(source, key, value)
      :error -> source
    end
  end

  defp drop_nils(map) when is_map(map),
    do: Map.reject(map, fn {_k, v} -> is_nil(v) or v == "" end)

  defp drop_nils(other), do: other
end
