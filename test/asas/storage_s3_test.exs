defmodule Asas.Storage.S3Test do
  @moduledoc """
  The S3 adapter against a plug that answers like a bucket does.

  Untested before, which mattered most for the 404 clause: `get/1` has to return
  `{:error, :enoent}` and `delete/1` has to treat 404 as success, because a
  delete that fails on an already-absent object turns every retry into an error
  and every cleanup job into a red build.
  """

  use ExUnit.Case, async: false

  alias Asas.Storage

  setup do
    previous_otp_app = Application.get_env(:asas, :otp_app)
    previous = Application.get_env(:asas, Storage, [])

    Application.put_env(:asas, :otp_app, :asas)

    on_exit(fn ->
      Application.put_env(:asas, Storage, previous)

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
      Storage,
      [
        backend: Storage.S3,
        endpoint: "https://s3.test",
        bucket: "media",
        access_key_id: "AKIATEST",
        secret_access_key: "secret",
        region: "auto",
        # retry: :transient is the adapter's own decision and config cannot weaken
        # it, but retry_delay is not one of our options, so a test can keep the
        # backoff from turning three retries into fourteen seconds.
        req_options: [plug: plug, retry_delay: 0]
      ]
      |> Keyword.merge(extra)
    )
  end

  describe "put/3" do
    test "signs the request, sends the content type, and returns the key" do
      configure(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/media/a/b.png"
        assert ["image/png"] = Plug.Conn.get_req_header(conn, "content-type")

        # Req's :aws_sigv4 produces an Authorization header, not a query string.
        assert ["AWS4-HMAC-SHA256 " <> rest] = Plug.Conn.get_req_header(conn, "authorization")
        assert rest =~ "Credential=AKIATEST"
        assert rest =~ "/auto/s3/aws4_request"

        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, "a/b.png"} = Storage.S3.put("a/b.png", <<137, 80, 78, 71>>, "image/png")
    end

    test "a non-2xx is data, not a raise" do
      configure(fn conn -> Plug.Conn.resp(conn, 403, "AccessDenied") end)

      assert {:error, {:http, 403, "AccessDenied"}} = Storage.S3.put("k", "b", "text/plain")
    end

    test "a transport failure comes back as the reason" do
      configure(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Storage.S3.put("k", "b", "text/plain")
    end
  end

  describe "get/1" do
    test "200 returns the body" do
      configure(fn conn -> Plug.Conn.resp(conn, 200, "hello") end)
      assert {:ok, "hello"} = Storage.S3.get("k")
    end

    test "404 is :enoent, not a generic http error" do
      configure(fn conn -> Plug.Conn.resp(conn, 404, "NoSuchKey") end)
      assert {:error, :enoent} = Storage.S3.get("missing")
    end

    test "any other status keeps the status and body" do
      configure(fn conn -> Plug.Conn.resp(conn, 500, "boom") end)
      assert {:error, {:http, 500, "boom"}} = Storage.S3.get("k")
    end
  end

  describe "delete/1" do
    test "200, 204 and 404 are all :ok — deleting an absent object is done, not failed" do
      for status <- [200, 204, 404] do
        configure(fn conn -> Plug.Conn.resp(conn, status, "") end)
        assert :ok = Storage.S3.delete("k")
      end
    end

    test "anything else is an error" do
      configure(fn conn -> Plug.Conn.resp(conn, 403, "") end)
      assert {:error, {:http, 403}} = Storage.S3.delete("k")
    end
  end

  describe "url/1" do
    test "falls back to endpoint/bucket when no public_url is set" do
      configure(fn conn -> Plug.Conn.resp(conn, 200, "") end)
      assert Storage.S3.url("a/b.png") == "https://s3.test/media/a/b.png"
    end

    test "prefers the CDN origin when one is configured" do
      configure(fn conn -> Plug.Conn.resp(conn, 200, "") end,
        public_url: "https://cdn.example.test"
      )

      assert Storage.S3.url("a/b.png") == "https://cdn.example.test/a/b.png"
    end
  end
end
