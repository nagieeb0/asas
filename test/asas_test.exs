defmodule AsasTest do
  use ExUnit.Case, async: true

  describe "Digits" do
    test "folds Arabic and Persian digits, and the separators" do
      assert Asas.Digits.latin("٠١٢٣٤٥٦٧٨٩") == "0123456789"
      assert Asas.Digits.latin("۰۱۲۳۴۵۶۷۸۹") == "0123456789"
      # The thousands mark is dropped, not translated — see the regression below.
      assert Asas.Digits.latin("٣٬٤٥٠٫٥٠") == "3450.50"
    end

    test "REGRESSION: the thousands separator must not become a comma" do
      # Mapping U+066C to "," reads correctly and destroys money silently:
      # Decimal.parse/1 stops at the comma, so ١٬٥٠٠ arrives as 1.
      folded = Asas.Digits.latin("١٬٥٠٠")

      assert folded == "1500"
      assert {decimal, ""} = Decimal.parse(folded)
      assert Decimal.equal?(decimal, Decimal.new(1500))
      refute folded =~ ","
    end

    test "strips the bidi marks that ride along on a copy out of an RTL page" do
      assert Asas.Digits.latin("‏٩٩‎") == "99"
    end

    test "leaves Arabic letters alone — this is a number fold, not a transliterator" do
      assert Asas.Digits.latin("قهوة ٩٥") == "قهوة 95"
    end

    test "ar/1 is the inverse for digits and leaves punctuation" do
      assert Asas.Digits.ar("3,450.00") == "٣,٤٥٠.٠٠"
      assert Asas.Digits.ar(16) == "١٦"
      assert Asas.Digits.ar(nil) == ""
    end

    test "normalize_params walks nested maps and lists" do
      params = %{"price" => "٩٩", "tags" => ["٥", "x"], "nested" => %{"qty" => "٣"}}

      assert Asas.Digits.normalize_params(params) ==
               %{"price" => "99", "tags" => ["5", "x"], "nested" => %{"qty" => "3"}}
    end
  end

  describe "Phone" do
    test "every shape an Egyptian mobile is typed in lands on one string" do
      for input <- [
            "01012345678",
            "+201012345678",
            "201012345678",
            "00201012345678",
            "010 1234 5678",
            "(010) 1234-5678",
            "٠١٠١٢٣٤٥٦٧٨"
          ] do
        assert Asas.Phone.e164(input) == {:ok, "+201012345678"}, "failed for #{inspect(input)}"
      end
    end

    test "every shape a Saudi mobile is typed in lands on one string" do
      for input <- ["0551234567", "+966551234567", "966551234567", "00966551234567", "551234567"] do
        assert Asas.Phone.e164(input) == {:ok, "+966551234567"}, "failed for #{inspect(input)}"
      end
    end

    test "length is what separates the two, not the operator digit" do
      # 10 digits after the trunk 0 is Egyptian, 9 is Saudi. Swap these and every
      # Egyptian is silently a Saudi whose OTP goes nowhere.
      assert Asas.Phone.e164("01012345678") == {:ok, "+201012345678"}
      assert Asas.Phone.e164("0501234567") == {:ok, "+966501234567"}
    end

    test "an operator prefix the regulator assigned last year is still accepted" do
      # The bug this guards: an owner's 0511… was refused by a hardcoded
      # whitelist and nobody could be admin.
      assert Asas.Phone.e164("0511792082") == {:ok, "+966511792082"}
    end

    test "landlines, short codes and foreign numbers are refused" do
      for input <- ["0223456789", "0112345678", "12345", "+14155550123", nil, "", "abc"] do
        assert Asas.Phone.e164(input) == :error, "accepted #{inspect(input)}"
      end
    end

    test "display helpers" do
      assert Asas.Phone.pretty("+966551234567") == "+966 55 123 4567"
      assert Asas.Phone.pretty("+201012345678") == "+20 101 234 5678"
      assert Asas.Phone.pretty(nil) == ""
      assert Asas.Phone.whatsapp("01012345678") == "201012345678"
      assert Asas.Phone.whatsapp("12345") == nil
      assert Asas.Phone.tail("+966551234567") == "4567"
    end
  end

  describe "RateLimit" do
    setup do
      start_supervised!({Asas.RateLimit, window_ms: 60_000})
      :ok
    end

    test "allows up to the limit then reports a retry-after" do
      key = "test-#{System.unique_integer()}"
      assert {:ok, 2} = Asas.RateLimit.hit(key, 3)
      assert {:ok, 1} = Asas.RateLimit.hit(key, 3)
      assert {:ok, 0} = Asas.RateLimit.hit(key, 3)
      assert {:error, retry} = Asas.RateLimit.hit(key, 3)
      assert retry > 0 and retry <= 60
    end

    test "keys do not share a window" do
      a = "a-#{System.unique_integer()}"
      b = "b-#{System.unique_integer()}"

      assert {:error, _} =
               (fn ->
                  Asas.RateLimit.hit(a, 1)
                  Asas.RateLimit.hit(a, 1)
                end).()

      assert {:ok, 0} = Asas.RateLimit.hit(b, 1)
    end
  end

  describe "Storage (local)" do
    setup do
      root = Path.join(System.tmp_dir!(), "asas-#{System.unique_integer([:positive])}")
      Application.put_env(:asas, :otp_app, :asas)
      Application.put_env(:asas, Asas.Storage, backend: Asas.Storage.Local, root: root)
      on_exit(fn -> File.rm_rf!(root) end)
      :ok
    end

    test "round-trips a blob under a server-invented key" do
      assert {:ok, key} = Asas.Storage.build_key("accounts/abc", "logo", "image/png")
      assert key =~ ~r{^accounts/abc/logo/[\w-]+\.png$}
      assert {:ok, ^key} = Asas.Storage.put(key, "bytes", "image/png")
      assert {:ok, "bytes"} = Asas.Storage.get(key)
      assert Asas.Storage.url(key) == "/uploads/" <> key
      assert :ok = Asas.Storage.delete(key)
      assert {:error, :enoent} = Asas.Storage.get(key)
    end

    test "an executable content type gets no key at all" do
      assert {:error, :unsupported_type} =
               Asas.Storage.build_key("a", "b", "application/x-httpd-php")
    end

    test "a traversing key is refused at the filesystem boundary" do
      assert_raise ArgumentError, fn -> Asas.Storage.put("../../etc/passwd", "x", "image/png") end
    end

    test "data_uri types from the bytes, not from the caller's claim" do
      png = <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0>>
      {:ok, key} = Asas.Storage.build_key("s", "k", "image/jpeg")
      {:ok, ^key} = Asas.Storage.put(key, png, "image/jpeg")
      assert {:ok, "data:image/png;base64," <> _} = Asas.Storage.data_uri(key)

      {:ok, html_key} = Asas.Storage.build_key("s", "k", "image/png")
      {:ok, ^html_key} = Asas.Storage.put(html_key, "<html>oops</html>", "image/png")
      assert {:error, :unrecognised_content} = Asas.Storage.data_uri(html_key)
    end
  end

  describe "Locale" do
    import Plug.Test
    import Plug.Conn

    @opts Asas.Locale.init(locales: ~w(ar en), default: "ar")

    defp run(conn) do
      conn
      |> Plug.Session.call(
        Plug.Session.init(store: :cookie, key: "_s", signing_salt: "salt", secret_key_base: nil)
      )
      |> fetch_session()
      |> Asas.Locale.call(@opts)
    end

    defp conn_with(path, headers \\ []) do
      Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
    end

    test "dir/1" do
      assert Asas.Locale.dir("ar") == "rtl"
      assert Asas.Locale.dir("ar-EG") == "rtl"
      assert Asas.Locale.dir("en") == "ltr"
    end

    test "an explicit param wins and is remembered in the session" do
      conn = "/?locale=en" |> conn_with() |> fetch_query_params() |> run()
      assert conn.assigns.locale == "en"
      assert conn.assigns.dir == "ltr"
      assert get_session(conn, "locale") == "en"
    end

    test "accept-language is consulted, with the region dropped" do
      # "ar-EG;q=0.9" must resolve to "ar" — keep the region and it silently
      # falls through to the default, which is the half-translated-page bug.
      conn =
        "/" |> conn_with([{"accept-language", "ar-EG,en;q=0.8"}]) |> fetch_query_params() |> run()

      assert conn.assigns.locale == "ar"
      assert conn.assigns.dir == "rtl"
    end

    test "an unsupported language falls back to the default rather than passing through" do
      conn = "/?locale=fr" |> conn_with() |> fetch_query_params() |> run()
      assert conn.assigns.locale == "ar"
    end
  end

  describe "Release macro" do
    test "expands into migrate/rollback/seed" do
      # No database here: this is a compile-time smoke test, and the macro
      # breaking is the failure mode that only shows up on a production boot.
      Code.ensure_loaded!(Asas.FakeRelease)

      for {fun, arity} <- [migrate: 0, rollback: 2, seed: 0] do
        assert function_exported?(Asas.FakeRelease, fun, arity),
               "Asas.Release did not define #{fun}/#{arity}"
      end
    end
  end
end
