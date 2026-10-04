defmodule Retake.Providers.Adapters.Download do
  @moduledoc """
  Fetching a media file for a stock adapter, safely. The URL comes out of an API
  response, so it is checked before it is fetched:

    * https only, and only the hosts the adapter allows (a host matches itself or any
      subdomain: `pexels.com` allows `videos.pexels.com`, not `evilpexels.com`,
      `pexels.com.evil.example` or `https://pexels.com@evil.example`);
    * redirects are not followed, so a redirect cannot lead somewhere else;
    * no credentials are sent;
    * a file over the provider's `max_download_bytes` (default 200 MB) is refused;
    * only known media types are accepted: the extension comes from the URL, else the
      `Content-Type` (mp4, jpg, png).

  Returns `{:binary, bytes, extension}` like any adapter output.
  """

  alias Retake.Providers.Adapters.Http
  alias Retake.Providers.Provider

  @default_max_bytes 200_000_000
  @extensions %{
    ".mp4" => {"mp4", "video/mp4"},
    ".jpg" => {"jpg", "image/jpeg"},
    ".jpeg" => {"jpg", "image/jpeg"},
    ".png" => {"png", "image/png"}
  }
  @content_types %{
    "video/mp4" => "mp4",
    "image/jpeg" => "jpg",
    "image/png" => "png"
  }

  @doc """
  Downloads `request["url"]` if its host is in `allowed_hosts`. `adapter` is the calling
  adapter module (its `Req` options come from `Retake.Providers.Adapters.Http.options/1`).
  """
  @spec fetch(module(), Provider.t(), map(), [String.t()]) ::
          {:ok, {:binary, binary(), String.t()}, map()} | {:error, term()}
  def fetch(adapter, %Provider{} = provider, request, allowed_hosts) do
    max_bytes = provider.options["max_download_bytes"] || @default_max_bytes

    with {:ok, url} <- allowed_url(request["url"], allowed_hosts) do
      options =
        [url: url, receive_timeout: 120_000, retry: false, decode_body: false, redirect: false]
        |> Keyword.merge(Http.options(adapter))

      case options |> Req.new() |> Req.request() do
        {:ok, %Req.Response{status: 200, body: bytes} = response} when is_binary(bytes) ->
          with :ok <- check_size(bytes, max_bytes),
               {:ok, extension} <- extension(url, response) do
            {:ok, {:binary, bytes, extension},
             %{cost_usd: 0.0, units: %{"bytes" => byte_size(bytes)}}}
          end

        other ->
          Http.failure(other, nil)
      end
    end
  end

  @doc "The MIME type a URL's extension suggests, or `default`."
  @spec mime(String.t(), String.t()) :: String.t()
  def mime(url, default) do
    case Map.get(@extensions, url_extension(url)) do
      {_extension, mime} -> mime
      nil -> default
    end
  end

  defp allowed_url(url, allowed_hosts) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if allowed_host?(String.downcase(host), allowed_hosts) do
          {:ok, url}
        else
          {:error, {:bad_request, "downloads from #{host} are not allowed"}}
        end

      _ ->
        {:error, {:bad_request, "the download url must be an https url"}}
    end
  end

  defp allowed_url(_other, _allowed_hosts), do: {:error, {:bad_request, "download needs a url"}}

  defp allowed_host?(host, allowed) do
    Enum.any?(allowed, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  defp check_size(bytes, max) when byte_size(bytes) <= max, do: :ok
  defp check_size(bytes, max), do: {:error, {:too_large, byte_size(bytes), max}}

  defp extension(url, response) do
    with :error <- from_url(url),
         :error <- from_content_type(response) do
      {:error, {:bad_response, "cannot tell the file type of #{url}"}}
    end
  end

  defp from_url(url) do
    case Map.get(@extensions, url_extension(url)) do
      {extension, _mime} -> {:ok, extension}
      nil -> :error
    end
  end

  defp from_content_type(response) do
    with [value | _] <- Req.Response.get_header(response, "content-type"),
         type = value |> String.split(";") |> hd() |> String.trim() |> String.downcase(),
         {:ok, extension} <- Map.fetch(@content_types, type) do
      {:ok, extension}
    else
      _ -> :error
    end
  end

  defp url_extension(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> path |> Path.extname() |> String.downcase()
      _ -> ""
    end
  end
end
