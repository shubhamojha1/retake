defmodule Retake.Providers.Adapters.Pixabay do
  @moduledoc """
  The `pixabay` adapter: free stock videos and photos (https://pixabay.com/api/docs/).
  Settings come from the provider in `config/providers.toml`: `orientation`
  (`"portrait"`/`"vertical"` or `"landscape"`/`"horizontal"`, photos only), `results_per_query`
  (default 5, Pixabay allows 3 to 200), `max_download_bytes`, and `base_url`
  (default `https://pixabay.com`). The API key goes in the `key` query parameter, as
  Pixabay wants.

  The requests and the candidates returned are the same as `Retake.Providers.Adapters.Pexels`
  documents, so a pipeline step works with either:

      %{"action" => "search", "kind" => "video" | "photo", "query" => "tea cup", "orientation" => "portrait"}
      %{"action" => "download", "url" => "https://cdn.pixabay.com/...mp4"}

  Pixabay differs in what it can do:

    * its video search has no orientation filter, so vertical clips are chosen by the
      caller from the file sizes;
    * a photo has up to three files: `largeImageURL` (at most 1280 px on the long side),
      `fullHDURL` (at most 1920 px) and `imageURL` (the original), the last two only for
      accounts Pixabay has approved for them. Their sizes are worked out from the
      original's size;
    * results are not to be hotlinked, which is why every file is downloaded to our storage.

  Downloads only come from `pixabay.com` hosts (`cdn.pixabay.com`); see
  `Retake.Providers.Adapters.Download`.
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Providers.Adapters.{Download, Http}
  alias Retake.Providers.Provider

  @default_base "https://pixabay.com"
  @default_per_page 5
  @max_query 100
  @allowed_hosts ["pixabay.com"]
  @license %{
    "name" => "Pixabay Content License",
    "url" => "https://pixabay.com/service/license-summary/"
  }
  @large_edge 1280
  @full_hd_edge 1920

  @impl true
  def call(%Provider{} = provider, api_key, %{"action" => "search"} = request) do
    search(provider, api_key, request)
  end

  def call(%Provider{} = provider, _api_key, %{"action" => "download"} = request) do
    Download.fetch(__MODULE__, provider, request, @allowed_hosts)
  end

  def call(_provider, _api_key, _request) do
    {:error, {:bad_request, ~s(the request needs "action": "search" or "download")}}
  end

  # --- search ------------------------------------------------------------------------

  defp search(_provider, nil, _request) do
    {:error, {:bad_request, "pixabay needs an API key: set api_key_env on the provider"}}
  end

  defp search(provider, key, request) do
    with {:ok, kind} <- kind(request["kind"]),
         {:ok, query} <- query(request["query"]) do
      options =
        [
          url: base(provider) <> path(kind),
          params: params(provider, request, kind, key, query),
          receive_timeout: 30_000,
          retry: false
        ]
        |> Keyword.merge(Http.options(__MODULE__))

      case options |> Req.new() |> Req.request() do
        {:ok, %Req.Response{status: 200, body: %{"hits" => hits}}} when is_list(hits) ->
          results = hits |> Enum.map(&normalize(kind, &1)) |> Enum.reject(&is_nil/1)

          {:ok, {:json, %{"results" => results}},
           %{cost_usd: 0.0, units: %{"results" => length(results)}}}

        {:ok, %Req.Response{status: 200, body: body}} ->
          {:error, {:unexpected_response, Http.message(body, key)}}

        other ->
          Http.failure(other, key)
      end
    end
  end

  defp path("video"), do: "/api/videos/"
  defp path("photo"), do: "/api/"

  defp params(provider, request, kind, key, query) do
    per_page = (provider.options["results_per_query"] || @default_per_page) |> max(3) |> min(200)
    base = [key: key, q: query, per_page: per_page, safesearch: "true"]

    case kind do
      "video" -> base
      "photo" -> base ++ [image_type: "photo"] ++ orientation(request, provider)
    end
  end

  # Pixabay's words are vertical and horizontal; ours are portrait and landscape.
  defp orientation(request, provider) do
    case request["orientation"] || provider.options["orientation"] do
      value when value in ["portrait", "vertical"] -> [orientation: "vertical"]
      value when value in ["landscape", "horizontal"] -> [orientation: "horizontal"]
      _ -> []
    end
  end

  defp kind(kind) when kind in ["video", "photo"], do: {:ok, kind}
  defp kind(_other), do: {:error, {:bad_request, ~s(search needs "kind": "video" or "photo")}}

  defp query(query) when is_binary(query) do
    if String.trim(query) == "",
      do: query(nil),
      else: {:ok, query |> String.trim() |> String.slice(0, @max_query)}
  end

  defp query(_other), do: {:error, {:bad_request, "search needs a query"}}

  defp base(provider) do
    String.trim_trailing(provider.options["base_url"] || @default_base, "/")
  end

  # --- normalising what Pixabay returns ----------------------------------------------------

  defp normalize("video", hit), do: video(hit)
  defp normalize("photo", hit), do: photo(hit)

  defp video(%{"id" => id, "videos" => sizes} = hit) when is_map(sizes) do
    files =
      for {_name, file} <- sizes,
          is_map(file),
          is_binary(file["url"]) and file["url"] != "",
          is_integer(file["width"]) and file["width"] > 0,
          is_integer(file["height"]) and file["height"] > 0 do
        %{
          "url" => file["url"],
          "width" => file["width"],
          "height" => file["height"],
          "mime" => "video/mp4"
        }
      end

    candidate("video", id, hit, seconds_to_ms(hit["duration"]), files)
  end

  defp video(_other), do: nil

  defp photo(%{"id" => id, "imageWidth" => width, "imageHeight" => height} = hit)
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    files =
      scaled(hit["largeImageURL"], width, height, @large_edge) ++
        scaled(hit["fullHDURL"], width, height, @full_hd_edge) ++
        original(hit["imageURL"], width, height)

    candidate("photo", id, hit, nil, files)
  end

  defp photo(_other), do: nil

  # A file the service scales to at most `edge` pixels on its long side, never up.
  defp scaled(url, width, height, edge) when is_binary(url) and url != "" do
    scale = min(1.0, edge / max(width, height))

    [file(url, round(width * scale), round(height * scale))]
  end

  defp scaled(_url, _width, _height, _edge), do: []

  defp original(url, width, height) when is_binary(url) and url != "",
    do: [file(url, width, height)]

  defp original(_url, _width, _height), do: []

  defp file(url, width, height) do
    %{
      "url" => url,
      "width" => width,
      "height" => height,
      "mime" => Download.mime(url, "image/jpeg")
    }
  end

  defp candidate(_kind, _id, _hit, _duration, []), do: nil

  defp candidate(kind, id, hit, duration_ms, files) do
    %{
      "kind" => kind,
      "id" => id,
      "page_url" => hit["pageURL"],
      "creator" => hit["user"],
      "creator_url" => creator_url(hit),
      "duration_ms" => duration_ms,
      "source" => "Pixabay",
      "license" => @license,
      "files" => Enum.sort_by(files, & &1["width"])
    }
  end

  defp creator_url(%{"user" => user, "user_id" => user_id})
       when is_binary(user) and is_integer(user_id) do
    "https://pixabay.com/users/#{user}-#{user_id}/"
  end

  defp creator_url(_hit), do: nil

  defp seconds_to_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp seconds_to_ms(_other), do: nil
end
