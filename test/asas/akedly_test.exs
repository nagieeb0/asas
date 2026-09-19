defmodule Asas.AkedlyTest do
  @moduledoc """
  The OTP client against a plug that answers like Akedly does.

  This module had no tests at all, which is the wrong shape for the one module
  here with a real external counterparty and credentials: it decides whether a
  phone number is proven, and a wrong answer is an account takeover rather than a
  formatting bug.

  `req_options` is the injection point. It was already being read out of config
  and then dropped on the floor, so these tests are also what proved the seam did
  not work.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Asas.Akedly

  setup do
    previous_otp_app = Application.get_env(:asas, :otp_app)
    previous = Application.get_env(:asas, Akedly, [])

    Application.put_env(:asas, :otp_app, :asas)

    on_exit(fn ->
      Application.put_env(:asas, Akedly, previous)

      if previous_otp_app do
        Application.put_env(:asas, :otp_app, previous_otp_app)
      else
        Application.delete_env(:asas, :otp_app)
      end
    end)

    :ok
  end

  defp configure(plug, extra \\ []) do
    Application.put_env(
      :asas,
      Akedly,
      [
        api_key: "ak_test",
        pipeline_id: "pipe_1",
        base_url: "https://api.akedly.test/api/v1.2",
        req_options: [plug: plug]
      ]
      |> Keyword.merge(extra)
    )
  end

  describe "configuration" do
    test "both credentials or nothing — a half-configured client never builds a request" do
      for cfg <- [
            [],
            [api_key: "ak_test"],
            [pipeline_id: "pipe_1"],
            [api_key: "", pipeline_id: ""]
          ] do
        Application.put_env(:asas, Akedly, cfg)

        refute Akedly.configured?()
        assert {:error, %{"code" => "AKEDLY_NOT_CONFIGURED"}} = Akedly.challenge()
        assert {:error, %{"code" => "AKEDLY_NOT_CONFIGURED"}} = Akedly.verify("t_1", "123456")

        assert {:error, %{"code" => "AKEDLY_NOT_CONFIGURED"}} =
                 Akedly.send_otp("+201012345678", %{}, nil, nil)
      end
    end

    test "configured? is true once both are present" do
      configure(fn conn -> Req.Test.json(conn, %{"status" => "success"}) end)
      assert Akedly.configured?()
    end
  end

  describe "the wire format" do
    test "challenge sends the credentials as query params, and never in a body" do
      configure(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.method == "GET"
        assert conn.request_path == "/api/v1.2/transactions/challenge"
        assert conn.query_params["APIKey"] == "ak_test"
        assert conn.query_params["pipelineID"] == "pipe_1"

        Req.Test.json(conn, %{"status" => "success", "data" => %{"challengeToken" => "c1"}})
      end)

      assert {:ok, %{"data" => %{"challengeToken" => "c1"}}} = Akedly.challenge()
    end

    test "send_otp forwards the end-user IP and the PoW solution" do
      configure(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1.2/transactions/send"
        assert Plug.Conn.get_req_header(conn, "x-end-user-ip") == ["203.0.113.9"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["APIKey"] == "ak_test"
        assert body["pipelineID"] == "pipe_1"
        assert body["verificationAddress"] == %{"phoneNumber" => "+201012345678"}
        assert body["powSolution"] == %{"challengeToken" => "c1", "nonce" => 42}
        assert body["turnstileToken"] == "cf_token"

        Req.Test.json(conn, %{
          "status" => "success",
          "data" => %{"transactionReqID" => "tr_1"}
        })
      end)

      assert {:ok, %{"data" => %{"transactionReqID" => "tr_1"}}} =
               Akedly.send_otp(
                 "+201012345678",
                 %{"challengeToken" => "c1", "nonce" => 42},
                 "cf_token",
                 "203.0.113.9"
               )
    end

    test "a missing end-user IP becomes an empty header rather than a crash" do
      configure(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-end-user-ip") == [""]
        Req.Test.json(conn, %{"status" => "success"})
      end)

      assert {:ok, _} = Akedly.send_otp("+201012345678", %{}, nil, nil)
    end

    test "verify stringifies an integer OTP, so a leading zero is not lost upstream" do
      configure(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["transactionReqID"] == "tr_1"
        assert body["otp"] == "123456"

        Req.Test.json(conn, %{"status" => "success", "data" => %{"verified" => true}})
      end)

      assert {:ok, body} = Akedly.verify("tr_1", 123_456)
      assert Akedly.verified?(body)
    end
  end

  describe "handle/1 — all four clauses" do
    test "a success body is {:ok, body}" do
      configure(fn conn -> Req.Test.json(conn, %{"status" => "success", "data" => %{}}) end)
      assert {:ok, %{"status" => "success"}} = Akedly.challenge()
    end

    test "a map body that is not a success is {:error, body}, upstream's own words" do
      configure(fn conn ->
        Req.Test.json(conn, %{"status" => "error", "code" => "INVALID_OTP"})
      end)

      assert {:error, %{"code" => "INVALID_OTP"}} = Akedly.verify("tr_1", "000000")
    end

    test "a non-map body becomes UPSTREAM_<status> and is logged" do
      configure(fn conn -> Plug.Conn.resp(conn, 502, "<html>gateway</html>") end)

      log =
        capture_log(fn ->
          assert {:error, %{"code" => "UPSTREAM_502"}} = Akedly.challenge()
        end)

      assert log =~ "akedly: unexpected 502"
    end

    test "a transport failure becomes AKEDLY_UNREACHABLE, and never leaks the key" do
      configure(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log =
        capture_log(fn ->
          assert {:error, %{"code" => "AKEDLY_UNREACHABLE"}} = Akedly.challenge()
        end)

      assert log =~ "akedly: request failed"
      refute log =~ "ak_test"
    end
  end

  describe "verify_webhook/5" do
    defp sign(secret_b64, id, ts, body) do
      {:ok, secret} = Base.decode64(secret_b64)
      :crypto.mac(:hmac, :sha256, secret, "#{id}.#{ts}.#{body}") |> Base.encode64()
    end

    setup do
      secret_b64 = Base.encode64("super-secret-bytes")
      Application.put_env(:asas, Akedly, webhook_secret: "whsec_" <> secret_b64)
      %{secret_b64: secret_b64, ts: to_string(System.system_time(:second))}
    end

    test "accepts a current, correctly signed delivery", %{secret_b64: s, ts: ts} do
      sig = sign(s, "msg_1", ts, "{}")
      assert :ok = Akedly.verify_webhook("msg_1", ts, "v1," <> sig, "{}")
    end

    test "accepts when any of several space-separated signatures matches", %{
      secret_b64: s,
      ts: ts
    } do
      good = sign(s, "msg_1", ts, "{}")
      header = "v1,AAAAinvalid v1," <> good

      assert :ok = Akedly.verify_webhook("msg_1", ts, header, "{}")
    end

    test "rejects a tampered body", %{secret_b64: s, ts: ts} do
      sig = sign(s, "msg_1", ts, "{}")

      assert {:error, :bad_signature} =
               Akedly.verify_webhook("msg_1", ts, "v1," <> sig, ~s({"amount":1}))
    end

    test "rejects a replay outside the five-minute window", %{secret_b64: s} do
      old = to_string(System.system_time(:second) - 301)
      sig = sign(s, "msg_1", old, "{}")

      assert {:error, :stale_timestamp} = Akedly.verify_webhook("msg_1", old, "v1," <> sig, "{}")
    end

    test "rejects a non-numeric timestamp rather than raising" do
      assert {:error, :stale_timestamp} =
               Akedly.verify_webhook("msg_1", "yesterday", "v1,x", "{}")
    end

    test "missing headers are refused before anything is computed" do
      assert {:error, :missing_headers} = Akedly.verify_webhook(nil, nil, nil, "{}")
    end

    test "an unconfigured secret is not a signature failure" do
      Application.put_env(:asas, Akedly, [])
      ts = to_string(System.system_time(:second))

      assert {:error, :not_configured} = Akedly.verify_webhook("msg_1", ts, "v1,x", "{}")
    end

    test "accepts the raw base64 form as well as whsec_", %{secret_b64: s, ts: ts} do
      Application.put_env(:asas, Akedly, webhook_secret: s)
      sig = sign(s, "msg_1", ts, "{}")

      assert :ok = Akedly.verify_webhook("msg_1", ts, "v1," <> sig, "{}")
    end
  end

  describe "with_status" do
    test "returns the upstream status for callers that proxy it to a browser" do
      configure(fn conn ->
        conn
        |> Plug.Conn.put_status(207)
        |> Req.Test.json(%{"status" => "success", "data" => %{}})
      end)

      assert {:ok, 207, %{"status" => "success"}} = Akedly.challenge(with_status: true)
      assert {:ok, %{"status" => "success"}} = Akedly.challenge()
    end

    test "a non-success map is still {:ok, status, body}, not an error, when asked" do
      configure(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"status" => "error", "message" => "bad otp"})
      end)

      assert {:ok, 400, %{"message" => "bad otp"}} = Akedly.verify("t", "0", with_status: true)
      assert {:error, %{"message" => "bad otp"}} = Akedly.verify("t", "0")
    end

    test "a transport failure is an error either way — there is no status to report" do
      configure(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %{"code" => "AKEDLY_UNREACHABLE"}} = Akedly.challenge(with_status: true)
    end
  end

  describe "verified?/1" do
    test "only an explicit success+verified is true" do
      assert Akedly.verified?(%{"status" => "success", "data" => %{"verified" => true}})

      refute Akedly.verified?(%{"status" => "success", "data" => %{"verified" => false}})
      refute Akedly.verified?(%{"status" => "success", "data" => %{}})
      refute Akedly.verified?(%{"status" => "error"})
      refute Akedly.verified?(%{})
      refute Akedly.verified?(%{"status" => "success", "data" => %{"verified" => "true"}})
    end
  end

  describe "req_options" do
    test "cannot override what the client decided — ours are merged over theirs" do
      configure(
        fn conn ->
          # retry: true and a different receive_timeout were asked for in config;
          # the request must still carry the client's own values.
          Req.Test.json(conn, %{"status" => "success"})
        end,
        req_options: [
          plug: fn conn -> Req.Test.json(conn, %{"status" => "success"}) end,
          retry: :transient,
          receive_timeout: 1
        ]
      )

      # A receive_timeout of 1ms from config would make this fail if it won.
      assert {:ok, %{"status" => "success"}} = Akedly.challenge()
    end
  end
end
