defmodule Retake.Pipeline.Stock do
  @moduledoc """
  Step 2 of the pipeline: a scene's `visual_query` becomes a stock video or photo,
  stored and ready to use as a spec asset. Nothing here knows which service answers;
  it works on the candidates every stock adapter returns (their shape is documented on the
  stock adapters, in the providers layer).

  Two provider calls per scene, both cached (decision D22): a search for candidates, then
  a download of the chosen file. The search tries videos first and photos only if no
  video is usable; if the query finds nothing it is retried with its first two words.

  Choosing among candidates, best first: a portrait file beats a landscape one, then a
  clip long enough for the narration beats a short one, then the provider's own ranking.
  Within a candidate the smallest file at least `:min_width` (default 1080) on its short
  side is used, else the largest available. A clip shorter than the narration is still
  used, with a warning: the renderer holds its last frame (decision D13).

  Talks to providers only through `Retake.Providers.Client`.
  """

  alias Retake.Cache.Entry
  alias Retake.Providers.Client

  @words_per_second 2.5
  @padding_ms 500
  @min_needed_ms 3_000
  @default_min_width 1080

  @type found :: %{asset: map(), query: String.t(), warnings: [String.t()]}

  @doc """
  Finds and downloads stock for `scene` (`%{narration: .., visual_query: ..}`, as
  `Retake.Pipeline.Script` returns them).

  Returns `{:ok, %{asset: asset, query: query, warnings: warnings}}` where `asset` is a
  spec asset (`kind`, `uri`, `content_hash`, `media`, `provenance`, `license`, string
  keys); `{:error, {:no_stock_found, queries}}` if nothing fits; or the provider error.
  """
  @spec find(Client.t(), %{narration: String.t(), visual_query: String.t()}, keyword()) ::
          {:ok, found()} | {:error, term()}
  def find(%Client{} = client, scene, opts \\ []) do
    queries = queries(scene.visual_query)

    context = %{
      needed_ms: needed_ms(scene.narration),
      min_width: Keyword.get(opts, :min_width, @default_min_width)
    }

    try_queries(client, queries, queries, context)
  end

  # --- queries ------------------------------------------------------------------------

  # The query as written, then its first two words (a broader search) if it has more.
  defp queries(visual_query) do
    query = String.trim(visual_query)

    case String.split(query) do
      [_, _, _ | _] = words -> [query, words |> Enum.take(2) |> Enum.join(" ")]
      _ -> [query]
    end
  end

  # How long the narration will run, so a clip can be judged long enough.
  defp needed_ms(narration) do
    words = narration |> String.split() |> length()
    max(round(words / @words_per_second * 1000) + @padding_ms, @min_needed_ms)
  end

  defp try_queries(_client, [], all, _context), do: {:error, {:no_stock_found, all}}

  defp try_queries(client, [query | rest], all, context) do
    case candidate(client, query, context) do
      {:ok, pick} -> download(client, pick, query, context)
      :none -> try_queries(client, rest, all, context)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- searching ----------------------------------------------------------------------

  defp candidate(client, query, context) do
    with {:ok, videos} <- search(client, "video", query) do
      case pick(videos, "video", context) do
        nil -> photo(client, query, context)
        pick -> {:ok, pick}
      end
    end
  end

  defp photo(client, query, context) do
    with {:ok, photos} <- search(client, "photo", query) do
      case pick(photos, "photo", context) do
        nil -> :none
        pick -> {:ok, pick}
      end
    end
  end

  defp search(client, kind, query) do
    request = %{
      "action" => "search",
      "kind" => kind,
      "query" => query,
      "orientation" => "portrait"
    }

    case Client.call(client, :stock, request) do
      {:ok, %Entry{result: {:json, %{"results" => results}}}, _outcome} when is_list(results) ->
        {:ok, results}

      {:ok, entry, _outcome} ->
        {:error, {:unexpected_search_result, entry.result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- choosing -----------------------------------------------------------------------

  defp pick(results, kind, context) do
    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {candidate, rank} -> usable(candidate, rank, kind, context) end)
    |> Enum.sort_by(&score(&1, context))
    |> List.first()
  end

  defp usable(%{"kind" => kind, "files" => files} = candidate, rank, kind, context)
       when is_list(files) do
    with true <-
           kind != "video" or
             (is_integer(candidate["duration_ms"]) and candidate["duration_ms"] > 0),
         %{} = file <- choose_file(files, context.min_width) do
      [%{candidate: candidate, file: file, rank: rank}]
    else
      _ -> []
    end
  end

  defp usable(_candidate, _rank, _kind, _context), do: []

  # The smallest file that is big enough on its short side, else the biggest there is.
  defp choose_file(files, min_width) do
    usable =
      Enum.filter(files, fn file ->
        is_binary(file["url"]) and is_integer(file["width"]) and is_integer(file["height"])
      end)

    big_enough = Enum.filter(usable, &(min(&1["width"], &1["height"]) >= min_width))

    cond do
      big_enough != [] -> Enum.min_by(big_enough, &pixels/1)
      usable != [] -> Enum.max_by(usable, &pixels/1)
      true -> nil
    end
  end

  defp pixels(file), do: file["width"] * file["height"]

  # Lower sorts first: portrait, then long enough, then the provider's order.
  defp score(%{candidate: candidate, file: file, rank: rank}, context) do
    portrait? = file["height"] >= file["width"]
    long_enough? = candidate["kind"] == "photo" or candidate["duration_ms"] >= context.needed_ms
    {not portrait?, not long_enough?, rank}
  end

  # --- downloading and describing ---------------------------------------------------------

  defp download(client, %{candidate: candidate, file: file, rank: rank}, query, context) do
    request = %{
      "action" => "download",
      "url" => file["url"],
      "kind" => candidate["kind"],
      "query" => query,
      "rank" => rank
    }

    case Client.call(client, :stock, request) do
      {:ok, %Entry{result: {:asset, ref}} = entry, _outcome} ->
        {:ok,
         %{
           asset: asset(candidate, file, ref, entry),
           query: query,
           warnings: warnings(candidate, context)
         }}

      {:ok, entry, _outcome} ->
        {:error, {:unexpected_download_result, entry.result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp asset(candidate, file, ref, entry) do
    %{
      "kind" => if(candidate["kind"] == "video", do: "video", else: "image"),
      "uri" => ref.uri,
      "content_hash" => ref.content_hash,
      "media" => media(candidate, file),
      "provenance" => Entry.provenance(entry),
      "license" => license(candidate)
    }
  end

  defp media(%{"kind" => "video"} = candidate, file) do
    %{
      "width" => file["width"],
      "height" => file["height"],
      "duration_ms" => candidate["duration_ms"],
      "mime" => file["mime"] || "video/mp4"
    }
  end

  defp media(_photo, file) do
    %{
      "width" => file["width"],
      "height" => file["height"],
      "mime" => file["mime"] || "image/jpeg"
    }
  end

  defp license(candidate) do
    source = candidate["source"]

    %{
      "name" =>
        get_in(candidate, ["license", "name"]) ||
          if(source, do: "#{source} License", else: "Stock license"),
      "source_url" => candidate["page_url"],
      "attribution" => attribution(candidate)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attribution(candidate) do
    noun = if candidate["kind"] == "video", do: "Video", else: "Photo"
    by = if candidate["creator"], do: " by #{candidate["creator"]}", else: ""
    on = if candidate["source"], do: " on #{candidate["source"]}", else: ""
    noun <> by <> on
  end

  defp warnings(%{"kind" => "video", "duration_ms" => duration}, %{needed_ms: needed})
       when duration < needed do
    [
      "the clip runs #{seconds(duration)} s but the narration needs about #{seconds(needed)} s: its last frame will be held"
    ]
  end

  defp warnings(_candidate, _context), do: []

  defp seconds(ms), do: Float.round(ms / 1000, 1)
end
