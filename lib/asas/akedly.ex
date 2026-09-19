defmodule Asas.Akedly do
  @moduledoc """
  Akedly **V1.2** phone OTP — https://docs.akedly.io/authentication/v1-2

  Three calls, in order:

    1. `challenge/0` — a proof-of-work challenge, plus whether this pipeline
       requires Cloudflare Turnstile. Valid five minutes.
    2. `send_otp/4` — delivers the SMS, given the solved PoW. Returns a
       `transactionReqID`.
    3. `verify/2` — checks the six-digit code against that transaction.

  ## The browser never talks to Akedly

  `APIKey` and `pipelineID` are credentials and stay on this side. The only
  thing the client does is solve the PoW hash, which is the entire point of a
  proof of work — Akedly makes the *client* prove work so that a flood of OTP
  sends costs the flooder something. `end_user_ip` is forwarded as
  `x-end-user-ip` so Akedly rate-limits the visitor rather than our one server
  IP; without it a single busy page looks like one abusive client.

  ## What `verify` does NOT tell you

  The v1.2 verify response carries `status`, `data.verified`,
  `data.transactionID`, `data.frontendCallbackURL` and `message` — and **no
  address of any kind**. The number a session is now authenticated as has to
  come from the send step that Akedly actually delivered the code to, held
  server-side. Never from the browser's word for it at verify time. That is the
  whole security boundary of this integration.

  ## Config

      config :my_app, Asas.Akedly,
        api_key: System.get_env("AKEDLY_API_KEY"),
        pipeline_id: System.get_env("AKEDLY_PIPELINE_ID")

  The OTP app is read from `:asas, :otp_app` (set it once in `config.exs`), or
  passed per call as `opts[:otp_app]`.

  Every function returns `{:ok, body}` when Akedly's body says
  `status: "success"` and `{:error, body}` otherwise, with Akedly's body
  verbatim — so a quota or rate-limit message reaches the person who can act
  on it instead of becoming "try again".
  """

  require Logger

  @base "https://api.akedly.io/api/v1.2"
  @timeout 15_000

  @doc "True once `api_key` and `pipeline_id` are both configured. Sign-in hides the phone option when false."
  @spec configured?(keyword) :: boolean
  def configured?(opts \\ []), do: match?({:ok, _}, config(opts))

  @doc "GET /transactions/challenge — PoW challenge and turnstile requirement."
  @spec challenge(keyword) :: {:ok, map} | {:error, map}
  def challenge(opts \\ []) do
    with {:ok, cfg} <- config(opts) do
      Req.get(
        cfg[:base_url] <> "/transactions/challenge",
        req_opts(cfg,
          params: [APIKey: cfg[:api_key], pipelineID: cfg[:pipeline_id]],
          receive_timeout: @timeout,
          retry: false
        )
      )
      |> handle(cfg)
    end
  end

  @doc """
  POST /transactions/send — deliver the OTP to `phone_number` (E.164).

  `pow` is the browser's `%{"challengeToken" => _, "nonce" => _}`, `turnstile`
  the Cloudflare token when the challenge asked for one, and `end_user_ip` the
  visitor's address.
  """
  @spec send_otp(binary, map, binary | nil, binary | nil, keyword) :: {:ok, map} | {:error, map}
  def send_otp(phone_number, pow, turnstile, end_user_ip, opts \\ []) do
    with {:ok, cfg} <- config(opts) do
      Req.post(
        cfg[:base_url] <> "/transactions/send",
        req_opts(cfg,
          headers: [{"x-end-user-ip", end_user_ip || ""}],
          json: %{
            "APIKey" => cfg[:api_key],
            "pipelineID" => cfg[:pipeline_id],
            "verificationAddress" => %{"phoneNumber" => phone_number},
            "powSolution" => pow,
            "turnstileToken" => turnstile
          },
          receive_timeout: @timeout,
          retry: false
        )
      )
      |> handle(cfg)
    end
  end

  @doc "POST /transactions/verify — check the code against a transaction."
  @spec verify(binary, binary | integer, keyword) :: {:ok, map} | {:error, map}
  def verify(transaction_req_id, otp, opts \\ []) do
    with {:ok, cfg} <- config(opts) do
      Req.post(
        cfg[:base_url] <> "/transactions/verify",
        req_opts(cfg,
          json: %{"transactionReqID" => transaction_req_id, "otp" => to_string(otp)},
          receive_timeout: @timeout,
          retry: false
        )
      )
      |> handle(cfg)
    end
  end

  @doc "Did Akedly verify this body? Read the moduledoc before trusting it for *which number*."
  @spec verified?(map) :: boolean
  def verified?(%{"status" => "success", "data" => %{"verified" => true}}), do: true
  def verified?(_body), do: false

  @doc """
  Verifies a Svix-style webhook signature, as Akedly sends it.

  Hand-rolled twice in this portfolio with incompatible results —
  `{:error, :bad_signature}` in one, the bare atom `:invalid` in the other — for
  the same algorithm and the same 5-minute window. This is keshfa's version, which
  was the complete one.

  `signature` may carry several space-separated `v1,<sig>` pairs; a delivery is
  accepted if any of them matches, which is how Svix rotates a secret without
  dropping messages. The comparison is constant-time, and the timestamp is checked
  before the MAC so a replay costs nothing.

  The secret is read from `webhook_secret` in the same config the client uses, and
  accepts either the raw base64 or the `whsec_`-prefixed form.
  """
  @spec verify_webhook(binary, binary, binary, binary, keyword) ::
          :ok | {:error, atom}
  def verify_webhook(id, timestamp, signature, raw_body, opts \\ [])

  def verify_webhook(id, timestamp, signature, raw_body, opts)
      when is_binary(id) and is_binary(timestamp) and is_binary(signature) do
    with {:ok, secret} <- webhook_secret(opts),
         :ok <- fresh_timestamp(timestamp) do
      expected =
        :crypto.mac(:hmac, :sha256, secret, "#{id}.#{timestamp}.#{raw_body}")
        |> Base.encode64()

      provided =
        signature
        |> String.split(" ", trim: true)
        |> Enum.map(fn part -> part |> String.split(",", parts: 2) |> List.last() end)

      if Enum.any?(provided, &Plug.Crypto.secure_compare(&1, expected)),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  def verify_webhook(_, _, _, _, _), do: {:error, :missing_headers}

  @doc "The configured webhook secret, decoded. `whsec_`-prefixed or raw base64."
  @spec webhook_secret(keyword) :: {:ok, binary} | {:error, atom}
  def webhook_secret(opts \\ []) do
    otp_app = opts[:otp_app] || Application.get_env(:asas, :otp_app)
    cfg = Keyword.merge(Application.get_env(otp_app, __MODULE__, []), opts)

    case cfg[:webhook_secret] do
      "whsec_" <> b64 -> decode_secret(b64)
      s when is_binary(s) and s != "" -> decode_secret(s)
      _ -> {:error, :not_configured}
    end
  end

  defp decode_secret(b64) do
    case Base.decode64(b64) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :bad_secret}
    end
  end

  # Reject replays and clock-skewed deliveries outside a 5-minute window.
  defp fresh_timestamp(timestamp) do
    with {ts, ""} <- Integer.parse(timestamp),
         true <- abs(System.system_time(:second) - ts) <= 300 do
      :ok
    else
      _ -> {:error, :stale_timestamp}
    end
  end

  # `with_status: true` returns {:ok, status, body} instead of {:ok, body}.
  #
  # Four of the copies of this client read the body and nothing else, which is the
  # right default: the status is transport detail and a caller that acts on it is
  # usually acting on the wrong thing. But ghadwa and khatm proxy this endpoint to
  # the browser and forward Akedly's own status with it, so for them the status is
  # the payload. Discarding it would have been a behaviour change on a live OTP
  # route, which is a bad reason to make someone keep a 95-line copy.
  defp handle(result, cfg) do
    case {result, cfg[:with_status]} do
      {{:ok, %Req.Response{status: s, body: %{"status" => "success"} = body}}, true} ->
        {:ok, s, body}

      {{:ok, %Req.Response{body: %{"status" => "success"} = body}}, _} ->
        {:ok, body}

      {{:ok, %Req.Response{status: s, body: body}}, true} when is_map(body) ->
        {:ok, s, body}

      {{:ok, %Req.Response{body: body}}, _} when is_map(body) ->
        {:error, body}

      {{:ok, %Req.Response{status: status, body: body}}, _} ->
        Logger.warning("akedly: unexpected #{status}: #{inspect(body)}")
        {:error, %{"status" => "error", "code" => "UPSTREAM_#{status}"}}

      {{:error, reason}, _} ->
        Logger.error("akedly: request failed: #{inspect(reason)}")
        {:error, %{"status" => "error", "code" => "AKEDLY_UNREACHABLE"}}
    end
  end

  defp config(opts) do
    otp_app = opts[:otp_app] || Application.get_env(:asas, :otp_app)
    cfg = Keyword.merge(Application.get_env(otp_app, __MODULE__, []), opts)

    if present?(cfg[:api_key]) and present?(cfg[:pipeline_id]) do
      {:ok,
       [
         base_url: cfg[:base_url] || @base,
         api_key: cfg[:api_key],
         pipeline_id: cfg[:pipeline_id]
       ] ++ Keyword.take(cfg, [:req_options, :with_status])}
    else
      {:error, %{"status" => "error", "code" => "AKEDLY_NOT_CONFIGURED"}}
    end
  end

  # `req_options` was already lifted out of config by config/1 and then never
  # used, so a host could set it and watch nothing happen. It is merged UNDER our
  # own options, the same way Asas.Moyasar does it: a config file may swap the
  # transport (which is how this is tested without a network, and how it would sit
  # behind an egress proxy) and may not redirect an authenticated request, change
  # its body, or strip its timeout.
  defp req_opts(cfg, own), do: Keyword.merge(cfg[:req_options] || [], own)

  defp present?(value), do: is_binary(value) and value != ""
end
