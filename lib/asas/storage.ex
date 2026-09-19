defmodule Asas.Storage do
  @moduledoc """
  One blob interface, two backends, chosen by config.

      config :my_app, Asas.Storage, backend: Asas.Storage.Local, root: "priv/static/uploads"

      config :my_app, Asas.Storage,
        backend: Asas.Storage.S3,
        endpoint: "https://fly.storage.tigris.dev",
        bucket: "my-app",
        region: "auto",
        access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
        public_url: System.get_env("BUCKET_PUBLIC_URL")

  ## A ref is a key, never a URL

  `put/3` returns the object key — an opaque `"a/b/c.png"`. That is what goes
  in `logo_key`, `avatar_key`, `pdf_key`. It survives a backend swap, and it
  is not a URL, because a URL in a database column is a URL that expires.

  ## Keys are invented by the server

  `build_key/3` is the only way to make one; the client's filename is never
  used, in any form. A real upload in one of these apps was named
  `MY LOGO (final) v2 ../../etc.png`.

  ## `data_uri/1` exists for one reason

  Anything rendering to PDF through headless Chrome must embed images as
  `data:` URIs, never as URLs. With egress blocked, Chrome renders a missing
  remote image and still writes a valid PDF with exit code 0 — no error, no
  warning. That silently logo-less PDF then gets approved and emailed to a
  paying customer, and nothing anywhere knew. `data_uri/1` types the URI from
  the stored bytes rather than from any column, so a mislabelled object comes
  back as an error instead of as `data:image/png;base64,<html document>`.
  """

  @callback put(key :: binary, binary, content_type :: binary) :: {:ok, binary} | {:error, term}
  @callback get(key :: binary) :: {:ok, binary} | {:error, term}
  @callback delete(key :: binary) :: :ok | {:error, term}
  @callback url(key :: binary) :: binary

  @doc "Stores `binary` at `key` and returns `{:ok, key}`."
  @spec put(binary, binary, binary, keyword) :: {:ok, binary} | {:error, term}
  def put(key, binary, content_type, opts \\ []), do: backend(opts).put(key, binary, content_type)

  @spec get(binary, keyword) :: {:ok, binary} | {:error, term}
  def get(key, opts \\ []), do: backend(opts).get(key)

  @spec delete(binary, keyword) :: :ok | {:error, term}
  def delete(key, opts \\ []), do: backend(opts).delete(key)

  @doc "Public URL for `key`. Passes absolute URLs and rooted paths straight through."
  @spec url(binary | nil, keyword) :: binary | nil
  def url(nil, _opts), do: nil
  def url("http" <> _ = url, _opts), do: url
  def url("/" <> _ = path, _opts), do: path
  def url(key, opts), do: backend(opts).url(key)
  def url(key), do: url(key, [])

  @doc """
  `"<scope>/<kind>/<uuid>.<ext>"` — the only sanctioned way to name an object.

  `ext` is taken from a whitelist keyed on content type, so an upload claiming
  to be a PNG cannot land as `.php`.
  """
  @spec build_key(binary, binary, binary) :: {:ok, binary} | {:error, :unsupported_type}
  def build_key(scope, kind, content_type) do
    case ext(content_type) do
      nil -> {:error, :unsupported_type}
      ext -> {:ok, "#{scope}/#{kind}/#{random_id()}.#{ext}"}
    end
  end

  @doc "The object as a `data:` URI, typed from its magic bytes. For PDF rendering — see the moduledoc."
  @spec data_uri(binary, keyword) :: {:ok, binary} | {:error, term}
  def data_uri(key, opts \\ []) do
    with {:ok, bytes} <- get(key, opts),
         {:ok, type} <- sniff(bytes) do
      {:ok, "data:#{type};base64,#{Base.encode64(bytes)}"}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :unrecognised_content}
    end
  end

  @doc false
  def config(opts) do
    otp_app = opts[:otp_app] || Application.get_env(:asas, :otp_app)
    Keyword.merge(Application.get_env(otp_app, __MODULE__, []), opts)
  end

  defp backend(opts), do: config(opts)[:backend] || Asas.Storage.Local

  defp ext("image/png"), do: "png"
  defp ext("image/jpeg"), do: "jpg"
  defp ext("image/webp"), do: "webp"
  defp ext("image/svg+xml"), do: "svg"
  defp ext("application/pdf"), do: "pdf"
  defp ext(_other), do: nil

  # The bytes decide, not the column. Same whitelist as ext/1, inverted.
  defp sniff(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp sniff(<<"RIFF", _::binary-4, "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp sniff(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf"}
  defp sniff(_other), do: :error

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
