defmodule Retake.Providers.Adapters.PixabayTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Adapters
  alias Retake.Providers.Adapters.Pixabay
  alias Retake.Providers.Provider

  @stub Pixabay

  @videos %{
    "total" => 3,
    "totalHits" => 3,
    "hits" => [
      %{
        "id" => 125,
        "pageURL" => "https://pixabay.com/videos/id-125/",
        "type" => "film",
        "tags" => "flowers, yellow",
        "duration" => 12,
        "user" => "Coverr-Free-Footage",
        "user_id" => 1_281_706,
        "videos" => %{
          "large" => %{
            "url" => "https://cdn.pixabay.com/video/2015/08/08/125_large.mp4",
            "width" => 1920,
            "height" => 1080,
            "size" => 6_615_235
          },
          "medium" => %{
            "url" => "https://cdn.pixabay.com/video/2015/08/08/125_medium.mp4",
            "width" => 1280,
            "height" => 720,
            "size" => 3_562_083
          },
          "small" => %{
            "url" => "https://cdn.pixabay.com/video/2015/08/08/125_small.mp4",
            "width" => 640,
            "height" => 360,
            "size" => 1_030_736
          },
          "tiny" => %{"url" => "", "width" => 0, "height" => 0, "size" => 0}
        }
      },
      %{
        "id" => 126,
        "pageURL" => "x",
        "duration" => 5,
        "user" => "u",
        "user_id" => 1,
        "videos" => %{}
      },
      %{"id" => 127, "pageURL" => "x", "duration" => 5, "user" => "u", "user_id" => 1}
    ]
  }

  @photos %{
    "total" => 3,
    "hits" => [
      %{
        "id" => 3001,
        "pageURL" => "https://pixabay.com/photos/tea-3001/",
        "user" => "tea_lover",
        "user_id" => 42,
        "imageWidth" => 4000,
        "imageHeight" => 6000,
        "largeImageURL" => "https://cdn.pixabay.com/photo/2020/01/01/tea-3001_1280.jpg",
        "fullHDURL" => "https://cdn.pixabay.com/photo/2020/01/01/tea-3001_1920.jpg",
        "imageURL" => "https://pixabay.com/get/tea-3001.jpg"
      },
      %{
        "id" => 3002,
        "pageURL" => "https://pixabay.com/photos/small-3002/",
        "user" => "someone",
        "user_id" => 7,
        "imageWidth" => 800,
        "imageHeight" => 600,
        "largeImageURL" => "https://cdn.pixabay.com/photo/2020/01/01/small-3002_1280.png"
      },
      %{"id" => 3003, "pageURL" => "x", "user" => "u", "imageWidth" => 100, "imageHeight" => 100}
    ]
  }

  defp provider(options \\ %{}) do
    %Provider{
      name: "pixabay",
      capability: :stock,
      adapter: "pixabay",
      api_key_env: "PIXABAY_API_KEY",
      options: Map.merge(%{"orientation" => "vertical", "results_per_query" => 5}, options)
    }
  end

  defp serve(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, {:request, conn})
      reply.(conn)
    end)
  end

  defp sent do
    assert_received {:request, conn}
    conn
  end

  defp search(kind, extra \\ %{}),
    do: Map.merge(%{"action" => "search", "kind" => kind, "query" => "steaming tea"}, extra)

  defp query_params(conn), do: Plug.Conn.fetch_query_params(conn).query_params

  test "the adapter is registered under the name pixabay" do
    assert Adapters.fetch("pixabay") == {:ok, Pixabay}
  end

  describe "search: the request" do
    test "videos: GET /api/videos/ with the key as a query parameter" do
      serve(&Req.Test.json(&1, @videos))
      assert {:ok, _, _} = Pixabay.call(provider(), "pix-key", search("video"))

      conn = sent()
      assert conn.method == "GET"
      assert conn.host == "pixabay.com"
      assert conn.request_path == "/api/videos/"
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      assert query_params(conn) == %{
               "key" => "pix-key",
               "q" => "steaming tea",
               "per_page" => "5",
               "safesearch" => "true"
             }
    end

    test "photos: GET /api/ asking for photos, vertical" do
      serve(&Req.Test.json(&1, @photos))

      assert {:ok, _, _} =
               Pixabay.call(
                 provider(),
                 "pix-key",
                 search("photo", %{"orientation" => "portrait"})
               )

      conn = sent()
      assert conn.request_path == "/api/"

      assert query_params(conn) == %{
               "key" => "pix-key",
               "q" => "steaming tea",
               "per_page" => "5",
               "safesearch" => "true",
               "image_type" => "photo",
               "orientation" => "vertical"
             }
    end

    test "orientation words: portrait and vertical, landscape and horizontal" do
      serve(&Req.Test.json(&1, @photos))

      Pixabay.call(
        provider(%{"orientation" => nil}),
        "k",
        search("photo", %{"orientation" => "landscape"})
      )

      assert query_params(sent())["orientation"] == "horizontal"

      Pixabay.call(provider(%{"orientation" => "portrait"}), "k", search("photo"))
      assert query_params(sent())["orientation"] == "vertical"

      Pixabay.call(provider(%{"orientation" => nil}), "k", search("photo"))
      refute Map.has_key?(query_params(sent()), "orientation")
    end

    test "per_page stays within Pixabay's 3 to 200" do
      serve(&Req.Test.json(&1, @videos))

      Pixabay.call(provider(%{"results_per_query" => 1}), "k", search("video"))
      assert query_params(sent())["per_page"] == "3"

      Pixabay.call(provider(%{"results_per_query" => 500}), "k", search("video"))
      assert query_params(sent())["per_page"] == "200"
    end

    test "the query is cut to Pixabay's 100 characters" do
      serve(&Req.Test.json(&1, @videos))
      Pixabay.call(provider(), "k", search("video", %{"query" => String.duplicate("a", 150)}))

      assert String.length(query_params(sent())["q"]) == 100
    end
  end

  describe "search: the answer" do
    test "videos: candidates with only the files that exist, smallest first" do
      serve(&Req.Test.json(&1, @videos))

      assert {:ok, {:json, %{"results" => [candidate]}}, %{units: %{"results" => 1}}} =
               Pixabay.call(provider(), "k", search("video"))

      assert candidate == %{
               "kind" => "video",
               "id" => 125,
               "page_url" => "https://pixabay.com/videos/id-125/",
               "creator" => "Coverr-Free-Footage",
               "creator_url" => "https://pixabay.com/users/Coverr-Free-Footage-1281706/",
               "duration_ms" => 12_000,
               "source" => "Pixabay",
               "license" => %{
                 "name" => "Pixabay Content License",
                 "url" => "https://pixabay.com/service/license-summary/"
               },
               "files" => [
                 %{
                   "url" => "https://cdn.pixabay.com/video/2015/08/08/125_small.mp4",
                   "width" => 640,
                   "height" => 360,
                   "mime" => "video/mp4"
                 },
                 %{
                   "url" => "https://cdn.pixabay.com/video/2015/08/08/125_medium.mp4",
                   "width" => 1280,
                   "height" => 720,
                   "mime" => "video/mp4"
                 },
                 %{
                   "url" => "https://cdn.pixabay.com/video/2015/08/08/125_large.mp4",
                   "width" => 1920,
                   "height" => 1080,
                   "mime" => "video/mp4"
                 }
               ]
             }
    end

    test "photos: the file sizes are worked out from the original's size" do
      serve(&Req.Test.json(&1, @photos))

      assert {:ok, {:json, %{"results" => [tea, small]}}, _} =
               Pixabay.call(provider(), "k", search("photo"))

      # 4000x6000: large is capped at 1280 on the long side, full HD at 1920, then the original
      assert Enum.map(tea["files"], &{&1["width"], &1["height"]}) == [
               {853, 1280},
               {1280, 1920},
               {4000, 6000}
             ]

      assert Enum.map(tea["files"], & &1["url"]) == [
               "https://cdn.pixabay.com/photo/2020/01/01/tea-3001_1280.jpg",
               "https://cdn.pixabay.com/photo/2020/01/01/tea-3001_1920.jpg",
               "https://pixabay.com/get/tea-3001.jpg"
             ]

      assert tea["creator"] == "tea_lover"
      assert tea["duration_ms"] == nil
      assert tea["source"] == "Pixabay"

      # an 800x600 image is never scaled up; a png url is a png
      assert [%{"width" => 800, "height" => 600, "mime" => "image/png"}] = small["files"]
    end

    test "a hit with no usable file or size is dropped" do
      serve(&Req.Test.json(&1, @photos))

      assert {:ok, {:json, %{"results" => results}}, _} =
               Pixabay.call(provider(), "k", search("photo"))

      assert Enum.map(results, & &1["id"]) == [3001, 3002]
    end

    test "no hits is an empty list" do
      serve(&Req.Test.json(&1, %{"total" => 0, "totalHits" => 0, "hits" => []}))

      assert {:ok, {:json, %{"results" => []}}, _} =
               Pixabay.call(provider(), "k", search("video"))
    end

    test "a body that is not a search result" do
      serve(&Req.Test.json(&1, %{"hello" => "world"}))
      assert {:error, {:unexpected_response, _}} = Pixabay.call(provider(), "k", search("video"))
    end
  end

  describe "search: failures" do
    test "Pixabay's plain-text error body is the message" do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Plug.Conn.send_resp(400, ~s([ERROR 400] Invalid or missing API key))
      end)

      # a realistic key: redaction replaces every occurrence of the key, so a one-letter key
      # would garble the word "key" in the message
      assert Pixabay.call(provider(), "pix-key-123", search("video")) ==
               {:error, {:http, 400, "[ERROR 400] Invalid or missing API key"}}
    end

    test "a rate limit" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 429, "API rate limit exceeded") end)

      assert Pixabay.call(provider(), "k", search("video")) ==
               {:error, {:http, 429, "API rate limit exceeded"}}
    end

    test "the API key is redacted if the service echoes it back" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 400, "bad key pix-secret-9") end)

      assert Pixabay.call(provider(), "pix-secret-9", search("video")) ==
               {:error, {:http, 400, "bad key [redacted]"}}
    end

    test "a transport failure" do
      serve(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert Pixabay.call(provider(), "k", search("video")) ==
               {:error, {:transport, :econnrefused}}
    end

    test "bad requests are rejected before anything is sent" do
      assert {:error, {:bad_request, _}} = Pixabay.call(provider(), nil, search("video"))
      assert {:error, {:bad_request, _}} = Pixabay.call(provider(), "k", search("audio"))

      assert {:error, {:bad_request, _}} =
               Pixabay.call(provider(), "k", search("video", %{"query" => ""}))

      assert {:error, {:bad_request, _}} = Pixabay.call(provider(), "k", %{"action" => "nope"})
      refute_received {:request, _}
    end
  end

  describe "download" do
    test "from cdn.pixabay.com: the bytes, the extension, no credentials" do
      serve(&Plug.Conn.send_resp(&1, 200, "VIDEO"))
      url = "https://cdn.pixabay.com/video/2015/08/08/125_medium.mp4"

      assert Pixabay.call(provider(), "pix-key", %{"action" => "download", "url" => url}) ==
               {:ok, {:binary, "VIDEO", "mp4"}, %{cost_usd: 0.0, units: %{"bytes" => 5}}}

      conn = sent()
      assert conn.host == "cdn.pixabay.com"
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert query_params(conn) == %{}
    end

    test "only Pixabay's own hosts, over https" do
      for url <- [
            "https://images.pexels.com/a.jpg",
            "https://evilpixabay.com/a.mp4",
            "https://pixabay.com.evil.example/a.mp4",
            "http://cdn.pixabay.com/a.mp4"
          ] do
        assert {:error, {:bad_request, _}} =
                 Pixabay.call(provider(), "k", %{"action" => "download", "url" => url}),
               url
      end

      refute_received {:request, _}
    end
  end
end
