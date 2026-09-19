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
      Req.get(cfg[:base_url] <> "/transactions/challenge",
        params: [APIKey: cfg[:api_key], pipelineID: cfg[:pipeline_id]],
        receive_timeout: @timeout,
        retry: false
      )
      |> handle()
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
      Req.post(cfg[:base_url] <> "/transactions/send",
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
      |> handle()
    end
  end

  @doc "POST /transactions/verify — check the code against a transaction."
  @spec verify(binary, binary | integer, keyword) :: {:ok, map} | {:error, map}
  def verify(transaction_req_id, otp, opts \\ []) do
    with {:ok, cfg} <- config(opts) do
      Req.post(cfg[:base_url] <> "/transactions/verify",
        json: %{"transactionReqID" => transaction_req_id, "otp" => to_string(otp)},
        receive_timeout: @timeout,
        retry: false
      )
      |> handle()
    end
  end

  @doc "Did Akedly verify this body? Read the moduledoc before trusting it for *which number*."
  @spec verified?(map) :: boolean
  def verified?(%{"status" => "success", "data" => %{"verified" => true}}), do: true
  def verified?(_body), do: false

  defp handle({:ok, %Req.Response{body: %{"status" => "success"} = body}}), do: {:ok, body}
  defp handle({:ok, %Req.Response{body: body}}) when is_map(body), do: {:error, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("akedly: unexpected #{status}: #{inspect(body)}")
    {:error, %{"status" => "error", "code" => "UPSTREAM_#{status}"}}
  end

  defp handle({:error, reason}) do
    Logger.error("akedly: request failed: #{inspect(reason)}")
    {:error, %{"status" => "error", "code" => "AKEDLY_UNREACHABLE"}}
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
       ] ++ Keyword.take(cfg, [:req_options])}
    else
      {:error, %{"status" => "error", "code" => "AKEDLY_NOT_CONFIGURED"}}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
