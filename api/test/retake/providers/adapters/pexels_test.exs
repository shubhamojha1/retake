defmodule Retake.Providers.Adapters.PexelsTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Adapters
  alias Retake.Providers.Adapters.Pexels
  alias Retake.Providers.Provider

  @stub Pexels

  @videos %{
    "page" => 1,
    "total_results" => 3,
    "videos" => [
      %{
        "id" => 1001,
        "url" => "https://www.pexels.com/video/steaming-cup-1001/",
        "duration" => 12,
        "user" => %{"name" => "A. Filmmaker", "url" => "https://www.pexels.com/@filmmaker"},
        "video_files" => [
          %{
            "quality" => "hd",
            "file_type" => "video/mp4",
            "width" => 1080,
            "height" => 1920,
            "link" => "https://videos.pexels.com/video-files/1001/1001-hd_1080_1920_30fps.mp4"
          },
          %{
            "quality" => "sd",
            "file_type" => "video/mp4",
            "width" => 720,
            "height" => 1280,
            "link" => "https://videos.pexels.com/video-files/1001/1001-sd_720_1280_30fps.mp4"
          },
          %{
            "quality" => "hls",
            "file_type" => "video/mp4",
            "width" => nil,
            "height" => nil,
            "link" => "https://videos.pexels.com/video-files/1001/1001.m3u8"
          },
          %{
            "quality" => "hd",
            "file_type" => "video/webm",
            "width" => 1080,
            "height" => 1920,
            "link" => "https://videos.pexels.com/video-files/1001/1001.webm"
          }
        ]
      },
      %{
        "id" => 1002,
        "url" => "https://www.pexels.com/video/nothing-usable-1002/",
        "duration" => 5,
        "user" => %{},
        "video_files" => []
      },
      %{
        "id" => 1003,
        "url" => "https://www.pexels.com/video/hls-only-1003/",
        "duration" => 5,
        "user" => %{},
        "video_files" => [
          %{
            "quality" => "hls",
            "file_type" => "video/mp4",
            "width" => 1,
            "height" => 1,
            "link" => "https://x/y.m3u8"
          }
        ]
      }
    ]
  }

  @photos %{
    "photos" => [
      %{
        "id" => 2001,
        "width" => 4000,
        "height" => 6000,
        "url" => "https://www.pexels.com/photo/tea-2001/",
        "photographer" => "B. Photographer",
        "photographer_url" => "https://www.pexels.com/@photog",
        "src" => %{
          "original" => "https://images.pexels.com/photos/2001/pexels-photo-2001.jpeg",
          "large2x" => "https://images.pexels.com/photos/2001/large2x.jpeg"
        }
      },
      %{
        "id" => 2002,
        "width" => 10,
        "height" => 10,
        "url" => "x",
        "photographer" => "C",
        "photographer_url" => "y",
        "src" => %{}
      }
    ]
  }

  defp provider(options \\ %{}) do
    %Provider{
      name: "pexels",
      capability: :stock,
      adapter: "pexels",
      api_key_env: "PEXELS_API_KEY",
      options: Map.merge(%{"orientation" => "portrait", "results_per_query" => 5}, options)
    }
  end

  # Stubs the server; the test process is told what the server saw.
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

  describe "the adapter is registered" do
    test "under the name pexels" do
      assert Adapters.fetch("pexels") == {:ok, Pexels}
    end
  end

  describe "search: the request" do
    test "videos: GET /videos/search with the key as the raw Authorization header" do
      serve(&Req.Test.json(&1, @videos))
      assert {:ok, _, _} = Pexels.call(provider(), "pex-key", search("video"))

      conn = sent()
      assert conn.method == "GET"
      assert conn.host == "api.pexels.com"
      assert conn.request_path == "/videos/search"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["pex-key"]

      assert query_params(conn) == %{
               "query" => "steaming tea",
               "orientation" => "portrait",
               "per_page" => "5"
             }
    end

    test "photos: GET /v1/search" do
      serve(&Req.Test.json(&1, @photos))
      assert {:ok, _, _} = Pexels.call(provider(), "pex-key", search("photo"))

      assert sent().request_path == "/v1/search"
    end

    test "results_per_query and a per-request orientation are honoured" do
      serve(&Req.Test.json(&1, @videos))

      Pexels.call(
        provider(%{"results_per_query" => 8}),
        "k",
        search("video", %{"orientation" => "landscape"})
      )

      params = query_params(sent())
      assert params["per_page"] == "8"
      assert params["orientation"] == "landscape"
    end

    test "sends no orientation when neither the request nor the provider sets one" do
      serve(&Req.Test.json(&1, @videos))
      Pexels.call(provider(%{"orientation" => nil}), "k", search("video"))

      refute Map.has_key?(query_params(sent()), "orientation")
    end
  end

  describe "search: the answer" do
    test "videos become candidates with only usable mp4 files, smallest first" do
      serve(&Req.Test.json(&1, @videos))

      assert {:ok, {:json, %{"results" => [candidate]}},
              %{cost_usd: +0.0, units: %{"results" => 1}}} =
               Pexels.call(provider(), "k", search("video"))

      assert candidate == %{
               "kind" => "video",
               "id" => 1001,
               "page_url" => "https://www.pexels.com/video/steaming-cup-1001/",
               "creator" => "A. Filmmaker",
               "creator_url" => "https://www.pexels.com/@filmmaker",
               "duration_ms" => 12_000,
               "source" => "Pexels",
               "license" => %{
                 "name" => "Pexels License",
                 "url" => "https://www.pexels.com/license/"
               },
               "files" => [
                 %{
                   "url" =>
                     "https://videos.pexels.com/video-files/1001/1001-sd_720_1280_30fps.mp4",
                   "width" => 720,
                   "height" => 1280,
                   "mime" => "video/mp4"
                 },
                 %{
                   "url" =>
                     "https://videos.pexels.com/video-files/1001/1001-hd_1080_1920_30fps.mp4",
                   "width" => 1080,
                   "height" => 1920,
                   "mime" => "video/mp4"
                 }
               ]
             }
    end

    test "photos become candidates with the original file" do
      serve(&Req.Test.json(&1, @photos))

      assert {:ok, {:json, %{"results" => [candidate]}}, _} =
               Pexels.call(provider(), "k", search("photo"))

      assert candidate == %{
               "kind" => "photo",
               "id" => 2001,
               "page_url" => "https://www.pexels.com/photo/tea-2001/",
               "creator" => "B. Photographer",
               "creator_url" => "https://www.pexels.com/@photog",
               "duration_ms" => nil,
               "source" => "Pexels",
               "license" => %{
                 "name" => "Pexels License",
                 "url" => "https://www.pexels.com/license/"
               },
               "files" => [
                 %{
                   "url" => "https://images.pexels.com/photos/2001/pexels-photo-2001.jpeg",
                   "width" => 4000,
                   "height" => 6000,
                   "mime" => "image/jpeg"
                 }
               ]
             }
    end

    test "no results is an empty list, not an error" do
      serve(&Req.Test.json(&1, %{"videos" => [], "total_results" => 0}))
      assert {:ok, {:json, %{"results" => []}}, _} = Pexels.call(provider(), "k", search("video"))
    end

    test "a body that is not a search result is an unexpected response" do
      serve(&Req.Test.json(&1, %{"hello" => "world"}))
      assert {:error, {:unexpected_response, _}} = Pexels.call(provider(), "k", search("video"))
    end
  end

  describe "search: failures" do
    test "an HTTP error carries the status and message" do
      serve(fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "Rate limit exceeded"})
      end)

      assert Pexels.call(provider(), "k", search("video")) ==
               {:error, {:http, 429, "Rate limit exceeded"}}
    end

    test "the API key is redacted if the service echoes it back" do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "Invalid key pex-secret-1"})
      end)

      assert Pexels.call(provider(), "pex-secret-1", search("video")) ==
               {:error, {:http, 401, "Invalid key [redacted]"}}
    end

    test "a transport failure" do
      serve(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert Pexels.call(provider(), "k", search("video")) == {:error, {:transport, :timeout}}
    end

    test "no API key, a bad kind, a blank query and an unknown action are bad requests, sent nowhere" do
      assert {:error, {:bad_request, _}} = Pexels.call(provider(), nil, search("video"))
      assert {:error, {:bad_request, _}} = Pexels.call(provider(), "k", search("audio"))

      assert {:error, {:bad_request, _}} =
               Pexels.call(provider(), "k", search("video", %{"query" => "  "}))

      assert {:error, {:bad_request, _}} = Pexels.call(provider(), "k", %{"action" => "delete"})
      refute_received {:request, _}
    end
  end

  describe "download" do
    @video_url "https://videos.pexels.com/video-files/1001/1001-hd_1080_1920_30fps.mp4"

    test "returns the bytes and the extension from the url" do
      serve(&Plug.Conn.send_resp(&1, 200, "VIDEO-BYTES"))

      assert Pexels.call(provider(), "k", %{"action" => "download", "url" => @video_url}) ==
               {:ok, {:binary, "VIDEO-BYTES", "mp4"}, %{cost_usd: 0.0, units: %{"bytes" => 11}}}

      conn = sent()
      assert conn.host == "videos.pexels.com"
      assert conn.request_path == "/video-files/1001/1001-hd_1080_1920_30fps.mp4"
    end

    test "never sends the API key to the file host" do
      serve(&Plug.Conn.send_resp(&1, 200, "x"))
      Pexels.call(provider(), "pex-secret", %{"action" => "download", "url" => @video_url})

      assert Plug.Conn.get_req_header(sent(), "authorization") == []
    end

    test "photos: the jpeg extension is stored as jpg" do
      serve(&Plug.Conn.send_resp(&1, 200, "PIXELS"))
      url = "https://images.pexels.com/photos/2001/pexels-photo-2001.jpeg"

      assert {:ok, {:binary, "PIXELS", "jpg"}, _} =
               Pexels.call(provider(), "k", %{"action" => "download", "url" => url})
    end

    test "falls back to the content type when the url has no extension" do
      serve(fn conn ->
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, "PNG")
      end)

      url = "https://images.pexels.com/photos/2001/download"

      assert {:ok, {:binary, "PNG", "png"}, _} =
               Pexels.call(provider(), "k", %{"action" => "download", "url" => url})
    end

    test "a file of an unknown type is refused" do
      serve(fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, "<html>")
      end)

      url = "https://images.pexels.com/photos/2001/download"

      assert {:error, {:bad_response, _}} =
               Pexels.call(provider(), "k", %{"action" => "download", "url" => url})
    end

    test "a file over max_download_bytes is refused" do
      serve(&Plug.Conn.send_resp(&1, 200, String.duplicate("x", 100)))

      assert Pexels.call(provider(%{"max_download_bytes" => 50}), "k", %{
               "action" => "download",
               "url" => @video_url
             }) ==
               {:error, {:too_large, 100, 50}}
    end

    test "an HTTP error is reported; redirects are not followed" do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example/x")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:http, 302, _}} =
               Pexels.call(provider(), "k", %{"action" => "download", "url" => @video_url})
    end
  end

  describe "download: which urls are allowed" do
    test "Pexels hosts and Vimeo, over https" do
      for url <- [
            "https://videos.pexels.com/a.mp4",
            "https://images.pexels.com/a.jpg",
            "https://pexels.com/a.jpg",
            "https://player.vimeo.com/external/1.mp4",
            "https://IMAGES.PEXELS.COM/a.jpg"
          ] do
        serve(&Plug.Conn.send_resp(&1, 200, "ok"))

        assert {:ok, {:binary, "ok", _}, _} =
                 Pexels.call(provider(), "k", %{"action" => "download", "url" => url}),
               url
      end
    end

    test "anything else is refused without a request being made" do
      for url <- [
            "http://videos.pexels.com/a.mp4",
            "https://evilpexels.com/a.mp4",
            "https://pexels.com.evil.example/a.mp4",
            "https://pexels.com@evil.example/a.mp4",
            "https://localhost/a.mp4",
            "https://169.254.169.254/latest/meta-data",
            "file:///etc/passwd",
            "ftp://videos.pexels.com/a.mp4",
            "videos.pexels.com/a.mp4",
            ""
          ] do
        assert {:error, {:bad_request, _}} =
                 Pexels.call(provider(), "k", %{"action" => "download", "url" => url}),
               url
      end

      assert {:error, {:bad_request, _}} = Pexels.call(provider(), "k", %{"action" => "download"})
      refute_received {:request, _}
    end
  end
end
