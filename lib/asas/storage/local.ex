defmodule Asas.Storage.Local do
  @moduledoc """
  Disk backend, under `config[:root]` (default `priv/static/uploads`) and served
  by `Plug.Static`.

  The default in dev and test, and the fallback anywhere S3 is unconfigured, so
  uploads work on a laptop with no cloud account. On a container platform this
  disk is ephemeral — it is never the production backend for anything a user
  expects to still be there tomorrow.
  """
  @behaviour Asas.Storage

  @impl true
  def put(key, binary, _content_type) do
    dest = path(key)
    File.mkdir_p!(Path.dirname(dest))

    case File.write(dest, binary) do
      :ok -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key), do: File.read(path(key))

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(key), do: "/" <> String.trim_leading(serve_prefix(), "/") <> "/" <> key

  # Traversal is refused here as well as at build_key/3: this is the boundary
  # that touches the filesystem, and a key can also arrive from an old DB row.
  defp path(key) do
    if String.contains?(key, "..") or String.starts_with?(key, "/") do
      raise ArgumentError, "unsafe storage key: #{inspect(key)}"
    end

    Path.join(cfg(:root) || "priv/static/uploads", key)
  end

  defp serve_prefix, do: cfg(:serve_prefix) || "uploads"
  defp cfg(key), do: Asas.Storage.config([])[key]
end
