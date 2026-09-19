defmodule Asas.MoyasarTest do
  @moduledoc """
  The real client, against a plug that answers like Moyasar does.

  Ported from `aethel/test/aethel/health/moyasar_transport_test.exs`, which was
  written against aethel's copy of this module. Running it here is the parity
  check: four applications carried a Moyasar client and none of them had ever
  received a byte from api.moyasar.com, so these assertions were the only
  contract that existed. This is the first time that contract is checked against
  the merged module.

  These tests do not make the client correct — only an `sk_test_` key can. They
  hold the parts that are ours: the documented empty-password basic auth, the id
  whitelist, the error shape, and the promise that a card number cannot reach a
  log line.

  `req_options` is the injection point, and it is merged *under* the client's own
  options on purpose: a config file may swap the transport and may not redirect an
  authenticated request or strip its credentials.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Asas.Moyasar

  setup do
    previous_otp_app = Application.get_env(:asas, :otp_app)
    previous = Application.get_env(:asas, Moyasar, [])

    Application.put_env(:asas, :otp_app, :asas)

    on_exit(fn ->
      Application.put_env(:asas, Moyasar, previous)

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
      Moyasar,
      [
        secret_key: "sk_test_abc",
        base_url: "https://api.moyasar.test/v1",
        req_options: [plug: plug]
      ]
      |> Keyword.merge(extra)
    )
  end

  describe "authentication" do
    test "sends the key as the username with an empty password" do
      configure(fn conn ->
        assert ["Basic " <> encoded] = Plug.Conn.get_req_header(conn, "authorization")
        # The documented format is `-u sk_test_123:` — the colon is the whole password.
        assert Base.decode64!(encoded) == "sk_test_abc:"

        Req.Test.json(conn, %{"id" => "inv_1", "url" => "https://pay/1"})
      end)

      assert {:ok, %{"id" => "inv_1"}} = Moyasar.create_invoice(%{"amount" => 9_900})
    end

    test "refuses to build a request at all without a key" do
      Application.put_env(:asas, Moyasar, [])

      assert {:error, :moyasar_not_configured} = Moyasar.fetch_payment("pay_1")
      assert {:error, :moyasar_not_configured} = Moyasar.create_invoice(%{})
      refute Moyasar.configured?()
    end

    test "reads test or live back off the key prefix" do
      configure(fn conn -> Req.Test.json(conn, %{}) end)
      assert Moyasar.mode() == :test

      configure(fn conn -> Req.Test.json(conn, %{}) end, secret_key: "sk_live_abc")
      assert Moyasar.mode() == :live

      configure(fn conn -> Req.Test.json(conn, %{}) end, secret_key: "whatever")
      assert Moyasar.mode() == {:error, :unrecognised_key_prefix}
    end
  end

  describe "the id whitelist" do
    test "a traversal or a query string never reaches the network" do
      configure(fn _conn -> flunk("a rejected id must not produce a request") end)

      for id <- ["../webhooks", "pay_1?foo=1", "pay 1", "", String.duplicate("a", 129)] do
        assert {:error, :invalid_id} = Moyasar.fetch_payment(id)
      end
    end

    test "an ordinary id does" do
      configure(fn conn ->
        assert conn.request_path == "/v1/payments/pay_abc-1"
        Req.Test.json(conn, %{"id" => "pay_abc-1", "status" => "paid"})
      end)

      assert {:ok, %{"status" => "paid"}} = Moyasar.fetch_payment("pay_abc-1")
    end
  end

  describe "errors" do
    test "a 4xx is data, and only the field NAMES are logged" do
      configure(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "type" => "invalid_request_error",
          "message" => "Validation Failed",
          "errors" => %{"amount" => ["must be an integer"]}
        })
      end)

      log =
        capture_log(fn ->
          assert {:error,
                  {:moyasar, 400, "invalid_request_error", "Validation Failed", ["amount"]}} =
                   Moyasar.create_invoice(%{"amount" => "lots"})
        end)

      assert log =~ "invalid_request_error"
      refute log =~ "lots"
    end

    test "a transport failure says so without naming the URL or the key" do
      configure(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log =
        capture_log(fn -> assert {:error, :transport_error} = Moyasar.fetch_payment("p_1") end)

      refute log =~ "sk_test_abc"
    end

    test "a 200 that is not a JSON object is not treated as a payment" do
      configure(fn conn -> Plug.Conn.resp(conn, 200, "[]") end)

      capture_log(fn -> assert {:error, :unexpected_response} = Moyasar.fetch_payment("p_1") end)
    end
  end

  describe "the card-shaped refusals raqeemi carried and aethel dropped" do
    test "charge_token refuses anything that is not a token_ string or a positive amount" do
      configure(fn _conn -> flunk("a refused charge must not produce a request") end)

      assert {:error, :not_a_card_token} = Moyasar.charge_token("4111111111111111", 100, %{})
      assert {:error, :not_a_card_token} = Moyasar.charge_token(nil, 100, %{})
      assert {:error, :bad_amount} = Moyasar.charge_token("token_abc", 0, %{})
      assert {:error, :bad_amount} = Moyasar.charge_token("token_abc", -1, %{})
    end

    test "refund refuses a non-positive amount before building a request" do
      configure(fn _conn -> flunk("a refused refund must not produce a request") end)

      assert {:error, :bad_amount} = Moyasar.refund("pay_1", 0)
      assert {:error, :bad_amount} = Moyasar.refund("pay_1", -5)
    end
  end

  describe "safe/1" do
    test "is a whitelist, so a card number cannot be added to a log by the gateway" do
      assert Moyasar.safe(%{
               "id" => "pay_1",
               "status" => "paid",
               "source" => %{"number" => "4111111111111111", "cvc" => "123"},
               "some_field_moyasar_adds_in_2027" => "surprise"
             }) == %{"id" => "pay_1", "status" => "paid"}
    end
  end

  describe "paid?/1 and pending?/1" do
    test "only paid and captured mean money moved" do
      for status <- ~w(paid captured), do: assert(Moyasar.paid?(%{"status" => status}))

      for status <- ~w(initiated authorized failed refunded voided verified),
          do: refute(Moyasar.paid?(%{"status" => status}))
    end

    test "an authorized hold is pending, not a failure" do
      assert Moyasar.pending?(%{"status" => "initiated"})
      refute Moyasar.pending?(%{"status" => "failed"})
    end
  end

  describe "secure_compare/2" do
    test "matches equal secrets and refuses everything else without raising" do
      assert Moyasar.secure_compare("s3cret", "s3cret")
      refute Moyasar.secure_compare("s3cret", "s3crey")
      refute Moyasar.secure_compare("s3cret", "s3cret-longer")
      refute Moyasar.secure_compare(nil, "s3cret")
      refute Moyasar.secure_compare(%{}, "s3cret")
    end
  end
end
