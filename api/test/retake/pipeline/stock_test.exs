defmodule Retake.Pipeline.StockTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Stock
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "l", fallbacks = [] }
  tts = { use = "t", fallbacks = [] }
  stt = { use = "s", fallbacks = [] }
  stock = { use = "stock", fallbacks = [] }
  music = { use = "m", fallbacks = [] }

  [providers.stock]
  capability = "stock"
  adapter = "fake"

  [providers.l]
  capability = "llm"
  adapter = "fake"

  [providers.t]
  capability = "tts"
  adapter = "fake"

  [providers.s]
  capability = "stt"
  adapter = "fake"

  [providers.m]
  capability = "music"
  adapter = "fake"
  """

  # 12 words: about 4.8 s of speech, so a clip needs to run about 5.3 s.
  @scene %{
    narration: "Ever wonder why a simple cup of tea can boost your health?",
    visual_query: "steaming tea cup closeup"
  }

  setup %{tmp_dir: dir} do
    {:ok, config} = Config.parse(@config)

    client =
      Client.new(
        config: config,
        profile: "dev",
        storage: Local.new(Path.join(dir, "store")),
        cache_root: Path.join(dir, "cache"),
        usage: start_supervised!(Usage)
      )

    %{client: client, dir: dir}
  end

  # --- candidates the fake stock service returns ---------------------------------------

  defp file(width, height, url \\ nil) do
    %{
      "url" => url || "https://cdn.test/#{width}x#{height}.mp4",
      "width" => width,
      "height" => height,
      "mime" => "video/mp4"
    }
  end

  defp video(id, files, opts \\ []) do
    %{
      "kind" => "video",
      "id" => id,
      "page_url" => "https://test.example/video/#{id}",
      "creator" => Keyword.get(opts, :creator, "A. Filmmaker"),
      "creator_url" => "https://test.example/@filmmaker",
      "duration_ms" => Keyword.get(opts, :duration_ms, 10_000),
      "source" => Keyword.get(opts, :source, "Pexels"),
      "license" => %{"name" => "Pexels License", "url" => "https://test.example/license"},
      "files" => files
    }
  end

  defp photo(id, width, height) do
    %{
      "kind" => "photo",
      "id" => id,
      "page_url" => "https://test.example/photo/#{id}",
      "creator" => "B. Photographer",
      "creator_url" => "https://test.example/@photographer",
      "duration_ms" => nil,
      "source" => "Pexels",
      "license" => %{"name" => "Pexels License", "url" => "https://test.example/license"},
      "files" => [
        %{
          "url" => "https://cdn.test/photo-#{id}.jpg",
          "width" => width,
          "height" => height,
          "mime" => "image/jpeg"
        }
      ]
    }
  end

  # results: %{{"video" | "photo", query} => [candidate]}; anything else finds nothing.
  defp serve(results) do
    Process.put(:fake_adapter_answers, %{
      "stock" => fn
        %{"action" => "search", "kind" => kind, "query" => query} ->
          {:ok, {:json, %{"results" => Map.get(results, {kind, query}, [])}}, %{}}

        %{"action" => "download", "url" => url} ->
          {:ok, {:binary, "bytes of " <> url, url |> Path.extname() |> String.trim_leading(".")},
           %{}}
      end
    })
  end

  defp calls do
    receive do
      {:adapter_called, "stock", _key, request} -> [request | calls()]
    after
      0 -> []
    end
  end

  defp actions(calls), do: Enum.map(calls, &{&1["action"], &1["kind"], &1["query"]})

  @query "steaming tea cup closeup"

  # --- choosing --------------------------------------------------------------------------

  describe "find/3: the happy path" do
    test "finds a video, downloads it and returns a spec asset", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920)])]})

      assert {:ok, %{asset: asset, query: @query, warnings: []}} = Stock.find(client, @scene)

      assert asset["kind"] == "video"

      assert asset["media"] == %{
               "width" => 1080,
               "height" => 1920,
               "duration_ms" => 10_000,
               "mime" => "video/mp4"
             }

      assert asset["content_hash"] ==
               Storage.content_hash("bytes of https://cdn.test/1080x1920.mp4")

      assert "store://assets/" <> _ = asset["uri"]
    end

    test "the downloaded bytes are in storage", %{client: client, dir: dir} do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920)])]})
      {:ok, %{asset: asset}} = Stock.find(client, @scene)

      assert Storage.fetch(Local.new(Path.join(dir, "store")), asset["uri"]) ==
               {:ok, "bytes of https://cdn.test/1080x1920.mp4"}
    end

    test "searches once for videos and downloads once", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920)])]})
      {:ok, _} = Stock.find(client, @scene)

      assert actions(calls()) == [{"search", "video", @query}, {"download", "video", @query}]
    end

    test "asks for portrait results", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920)])]})
      {:ok, _} = Stock.find(client, @scene)

      assert [%{"orientation" => "portrait"} | _] = calls()
    end

    test "licence, source page and attribution come from the candidate", %{client: client} do
      serve(%{
        {"video", @query} => [video(7, [file(1080, 1920)], creator: "Jo Doe", source: "Pixabay")]
      })

      {:ok, %{asset: asset}} = Stock.find(client, @scene)

      assert asset["license"] == %{
               "name" => "Pexels License",
               "source_url" => "https://test.example/video/7",
               "attribution" => "Video by Jo Doe on Pixabay"
             }
    end

    test "provenance records the service, how it was found and the file", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920, "https://cdn.test/a.mp4")])]})
      {:ok, %{asset: asset}} = Stock.find(client, @scene)

      provenance = asset["provenance"]
      assert provenance["source"] == "stock"
      assert provenance["capability"] == "stock"
      assert provenance["provider"] == "stock"

      assert provenance["request"] == %{
               "action" => "download",
               "url" => "https://cdn.test/a.mp4",
               "kind" => "video",
               "query" => @query,
               "rank" => 0
             }

      assert "sha256:" <> _ = provenance["request_hash"]
      assert provenance["cost"]["currency"] == "USD"
    end

    test "a repeat is answered entirely from the cache", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920)])]})
      {:ok, first} = Stock.find(client, @scene)
      _ = calls()

      assert {:ok, ^first} = Stock.find(client, @scene)
      assert calls() == []
    end
  end

  describe "find/3: choosing a candidate" do
    test "prefers a portrait file over a landscape one", %{client: client} do
      landscape =
        video(1, [file(1920, 1080, "https://cdn.test/landscape.mp4")], duration_ms: 20_000)

      portrait =
        video(2, [file(1080, 1920, "https://cdn.test/portrait.mp4")], duration_ms: 20_000)

      serve(%{{"video", @query} => [landscape, portrait]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene)

      assert asset["content_hash"] ==
               Storage.content_hash("bytes of https://cdn.test/portrait.mp4")
    end

    test "prefers a clip long enough for the narration", %{client: client} do
      short = video(1, [file(1080, 1920, "https://cdn.test/short.mp4")], duration_ms: 3_000)
      long = video(2, [file(1080, 1920, "https://cdn.test/long.mp4")], duration_ms: 12_000)
      serve(%{{"video", @query} => [short, long]})

      {:ok, %{asset: asset, warnings: []}} = Stock.find(client, @scene)
      assert asset["content_hash"] == Storage.content_hash("bytes of https://cdn.test/long.mp4")
    end

    test "the narration's length sets how long is long enough", %{client: client} do
      # 25 words need about 10.5 s: 8 s is not enough, 12 s is
      narration = Enum.join(List.duplicate("word", 25), " ")
      eight = video(1, [file(1080, 1920, "https://cdn.test/eight.mp4")], duration_ms: 8_000)
      twelve = video(2, [file(1080, 1920, "https://cdn.test/twelve.mp4")], duration_ms: 12_000)
      serve(%{{"video", @query} => [eight, twelve]})

      {:ok, %{asset: asset}} = Stock.find(client, %{@scene | narration: narration})
      assert asset["content_hash"] == Storage.content_hash("bytes of https://cdn.test/twelve.mp4")
    end

    test "uses a clip that is too short anyway, and warns that its last frame will be held", %{
      client: client
    } do
      serve(%{{"video", @query} => [video(1, [file(1080, 1920)], duration_ms: 3_000)]})

      assert {:ok, %{asset: %{"kind" => "video"}, warnings: [warning]}} =
               Stock.find(client, @scene)

      assert warning =~ "3.0 s"
      assert warning =~ "5.3 s"
      assert warning =~ "last frame"
    end

    test "uses the provider's order when everything else is equal", %{client: client} do
      first = video(1, [file(1080, 1920, "https://cdn.test/first.mp4")])
      second = video(2, [file(1080, 1920, "https://cdn.test/second.mp4")])
      serve(%{{"video", @query} => [first, second]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene)
      assert asset["content_hash"] == Storage.content_hash("bytes of https://cdn.test/first.mp4")
    end

    test "within a candidate: the smallest file that is big enough", %{client: client} do
      files = [file(480, 854), file(1080, 1920), file(2160, 3840)]
      serve(%{{"video", @query} => [video(1, files)]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene)
      assert asset["media"]["width"] == 1080
    end

    test "within a candidate: the largest file when none is big enough", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(480, 854), file(720, 1280)])]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene)
      assert asset["media"]["width"] == 720
    end

    test "min_width changes what is big enough", %{client: client} do
      serve(%{{"video", @query} => [video(1, [file(720, 1280), file(1080, 1920)])]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene, min_width: 700)
      assert asset["media"]["width"] == 720
    end

    test "skips candidates with no usable file and videos with no duration", %{client: client} do
      no_files = video(1, [])
      no_duration = video(2, [file(1080, 1920, "https://cdn.test/nodur.mp4")], duration_ms: nil)
      good = video(3, [file(1080, 1920, "https://cdn.test/good.mp4")])
      serve(%{{"video", @query} => [no_files, no_duration, good]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene)
      assert asset["content_hash"] == Storage.content_hash("bytes of https://cdn.test/good.mp4")
    end
  end

  describe "find/3: photos" do
    test "falls back to a photo when there is no usable video", %{client: client} do
      serve(%{{"photo", @query} => [photo(5, 1350, 2400)]})

      assert {:ok, %{asset: asset, warnings: []}} = Stock.find(client, @scene)
      assert asset["kind"] == "image"
      assert asset["media"] == %{"width" => 1350, "height" => 2400, "mime" => "image/jpeg"}
      assert asset["license"]["attribution"] == "Photo by B. Photographer on Pexels"
    end

    test "searches photos only when videos found nothing", %{client: client} do
      serve(%{
        {"video", @query} => [video(1, [file(1080, 1920)])],
        {"photo", @query} => [photo(5, 1350, 2400)]
      })

      {:ok, _} = Stock.find(client, @scene)

      assert Enum.map(calls(), & &1["kind"]) == ["video", "video"]
    end

    test "prefers a portrait photo", %{client: client} do
      serve(%{{"photo", @query} => [photo(1, 2400, 1350), photo(2, 1350, 2400)]})

      {:ok, %{asset: asset}} = Stock.find(client, @scene)

      assert asset["content_hash"] ==
               Storage.content_hash("bytes of https://cdn.test/photo-2.jpg")
    end
  end

  describe "find/3: broader queries and giving up" do
    test "retries the first two words when the full query finds nothing", %{client: client} do
      serve(%{{"video", "steaming tea"} => [video(1, [file(1080, 1920)])]})

      assert {:ok, %{query: "steaming tea"}} = Stock.find(client, @scene)

      assert actions(calls()) == [
               {"search", "video", @query},
               {"search", "photo", @query},
               {"search", "video", "steaming tea"},
               {"download", "video", "steaming tea"}
             ]
    end

    test "gives up when nothing is found, naming the queries tried", %{client: client} do
      serve(%{})

      assert Stock.find(client, @scene) == {:error, {:no_stock_found, [@query, "steaming tea"]}}
      refute Enum.any?(calls(), &(&1["action"] == "download"))
    end

    test "a query of two words or fewer is tried once", %{client: client} do
      serve(%{})

      assert Stock.find(client, %{@scene | visual_query: "tea cup"}) ==
               {:error, {:no_stock_found, ["tea cup"]}}

      assert Enum.count(calls(), &(&1["action"] == "search")) == 2
    end
  end

  describe "find/3: failures" do
    test "a provider failure on search is reported, not mistaken for no results", %{
      client: client
    } do
      Process.put(:fake_adapter_answers, %{"stock" => {:error, :boom}})

      assert {:error, {:all_providers_failed, [%{provider: "stock", reason: :boom}]}} =
               Stock.find(client, @scene)
    end

    test "a failed download is reported", %{client: client} do
      Process.put(:fake_adapter_answers, %{
        "stock" => fn
          %{"action" => "search"} ->
            {:ok, {:json, %{"results" => [video(1, [file(1080, 1920)])]}}, %{}}

          %{"action" => "download"} ->
            {:error, {:http, 404, "gone"}}
        end
      })

      assert {:error, {:all_providers_failed, [%{reason: {:http, 404, "gone"}}]}} =
               Stock.find(client, @scene)
    end
  end
end
