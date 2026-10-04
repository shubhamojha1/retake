defmodule Retake.Providers.Adapters.Pexels do
  @moduledoc """
  The `pexels` adapter: free stock videos and photos (https://www.pexels.com/api/).
  Settings come from the provider in `config/providers.toml`: `orientation`,
  `results_per_query` (default 5), `max_download_bytes` (default 200 MB), and
  `base_url` (default `https://api.pexels.com`). The API key is sent as the raw
  `Authorization` header, as Pexels wants (no `Bearer`).

  Two requests (string keys), both through `Retake.Providers.Client` (decision D22):

      %{"action" => "search", "kind" => "video" | "photo", "query" => "tea cup",
        "orientation" => "portrait"}      # orientation optional, else the provider's
      %{"action" => "download", "url" => "https://videos.pexels.com/...mp4"}

  A search returns `{:json, %{"results" => [candidate]}}`, each candidate

      %{"kind" => "video" | "photo", "id" => 1, "page_url" => "...", "creator" => "...",
        "creator_url" => "...", "duration_ms" => 12000 | nil,
        "source" => "Pexels", "license" => %{"name" => "...", "url" => "..."},
        "files" => [%{"url", "width", "height", "mime"}]}   # smallest first

  with only usable files (MP4 for video, the original for photos). A download returns
  `{:binary, bytes, extension}`; see `Retake.Providers.Adapters.Download` for how the
  URL is checked (Pexels' own hosts, and Vimeo, which Pexels has served video from).
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Providers.Adapters.{Download, Http}
  alias Retake.Providers.Provider

  @default_base "https://api.pexels.com"
  @default_per_page 5
  @allowed_hosts ["pexels.com", "vimeo.com"]
  @video_qualities ["hd", "sd", "uhd"]

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
    {:error, {:bad_request, "pexels needs an API key: set api_key_env on the provider"}}
  end

  defp search(provider, key, request) do
    with {:ok, kind} <- kind(request["kind"]),
         {:ok, query} <- query(request["query"]) do
      {path, list_key, normalize} = endpoint(kind)

      params =
        [query: query, per_page: provider.options["results_per_query"] || @default_per_page] ++
          orientation(request, provider)

      options =
        [
          url: base(provider) <> path,
          params: params,
          headers: [{"authorization", key}],
          receive_timeout: 30_000,
          retry: false
        ]
        |> Keyword.merge(Http.options(__MODULE__))

      case options |> Req.new() |> Req.request() do
        {:ok, %Req.Response{status: 200, body: %{^list_key => items}}} when is_list(items) ->
          results = items |> Enum.map(normalize) |> Enum.reject(&is_nil/1)

          {:ok, {:json, %{"results" => results}},
           %{cost_usd: 0.0, units: %{"results" => length(results)}}}

        {:ok, %Req.Response{status: 200, body: body}} ->
          {:error, {:unexpected_response, Http.message(body, key)}}

        other ->
          Http.failure(other, key)
      end
    end
  end

  defp endpoint("video"), do: {"/videos/search", "videos", &video/1}
  defp endpoint("photo"), do: {"/v1/search", "photos", &photo/1}

  defp kind(kind) when kind in ["video", "photo"], do: {:ok, kind}
  defp kind(_other), do: {:error, {:bad_request, ~s(search needs "kind": "video" or "photo")}}

  defp query(query) when is_binary(query) do
    if String.trim(query) == "", do: query(nil), else: {:ok, String.trim(query)}
  end

  defp query(_other), do: {:error, {:bad_request, "search needs a query"}}

  defp orientation(request, provider) do
    case request["orientation"] || provider.options["orientation"] do
      value when is_binary(value) -> [orientation: value]
      _ -> []
    end
  end

  defp base(provider) do
    String.trim_trailing(provider.options["base_url"] || @default_base, "/")
  end

  # --- normalising what Pexels returns ----------------------------------------------------

  defp video(%{"id" => id} = video) do
    files =
      for file <- video["video_files"] || [],
          file["file_type"] == "video/mp4",
          file["quality"] in @video_qualities,
          is_integer(file["width"]),
          is_integer(file["height"]),
          is_binary(file["link"]) do
        %{
          "url" => file["link"],
          "width" => file["width"],
          "height" => file["height"],
          "mime" => "video/mp4"
        }
      end

    candidate(
      "video",
      id,
      video["url"],
      get_in(video, ["user", "name"]),
      get_in(video, ["user", "url"]),
      seconds_to_ms(video["duration"]),
      files
    )
  end

  defp video(_other), do: nil

  defp photo(%{"id" => id} = photo) do
    original = get_in(photo, ["src", "original"])

    files =
      if is_binary(original) and is_integer(photo["width"]) and is_integer(photo["height"]) do
        [
          %{
            "url" => original,
            "width" => photo["width"],
            "height" => photo["height"],
            "mime" => Download.mime(original, "image/jpeg")
          }
        ]
      else
        []
      end

    candidate(
      "photo",
      id,
      photo["url"],
      photo["photographer"],
      photo["photographer_url"],
      nil,
      files
    )
  end

  defp photo(_other), do: nil

  # A result with no usable file is no use to the caller.
  defp candidate(_kind, _id, _page, _creator, _creator_url, _duration, []), do: nil

  defp candidate(kind, id, page_url, creator, creator_url, duration_ms, files) do
    %{
      "kind" => kind,
      "id" => id,
      "page_url" => page_url,
      "creator" => creator,
      "creator_url" => creator_url,
      "duration_ms" => duration_ms,
      "source" => "Pexels",
      "license" => %{"name" => "Pexels License", "url" => "https://www.pexels.com/license/"},
      "files" => Enum.sort_by(files, & &1["width"])
    }
  end

  defp seconds_to_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp seconds_to_ms(_other), do: nil
end
