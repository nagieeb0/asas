defmodule Asas.Storage.S3 do
  @moduledoc """
  Any S3-compatible bucket — Tigris, R2, AWS — signed with Req's native
  `:aws_sigv4`. No `ex_aws`, no extra dependency: `req` is already in every one
  of these apps.

  `public_url` is the CDN or public bucket origin `url/1` builds against. Leave
  it unset and the endpoint/bucket pair is used, which is right for a bucket
  whose objects are public and wrong for one that is not — in that case the
  caller wants a presigned URL, which this deliberately does not have (see
  `Asas.Storage`'s "a ref is a key").
  """
  @behaviour Asas.Storage

  @impl true
  def put(key, binary, content_type) do
    case Req.put(object_url(key),
           body: binary,
           headers: [{"content-type", content_type}],
           aws_sigv4: sigv4(),
           retry: :transient
         ) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, key}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    case Req.get(object_url(key), aws_sigv4: sigv4(), retry: :transient) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :enoent}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case Req.delete(object_url(key), aws_sigv4: sigv4(), retry: :transient) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(key), do: "#{cfg(:public_url) || "#{cfg(:endpoint)}/#{cfg(:bucket)}"}/#{key}"

  defp object_url(key), do: "#{cfg(:endpoint)}/#{cfg(:bucket)}/#{key}"

  defp sigv4 do
    [
      access_key_id: cfg(:access_key_id),
      secret_access_key: cfg(:secret_access_key),
      service: "s3",
      region: cfg(:region) || "auto"
    ]
  end

  defp cfg(key), do: Asas.Storage.config([])[key]
end
