defmodule RetakeWeb.VideoControllerTest do
  # Sets an app setting (the runner), so it cannot run alongside other tests.
  use RetakeWeb.ConnCase, async: false

  alias Retake.Test.{NoopRunner, RefusingRunner}
  alias Retake.Videos

  @moduletag :tmp_dir

  # 20 bytes, each different, so a slice shows which bytes were sent.
  @bytes "0123456789abcdefghij"

  setup do
    Application.put_env(:retake, :video_runner, NoopRunner)
    on_exit(fn -> Application.delete_env(:retake, :video_runner) end)
    :ok
  end

  defp queued_video do
    {:ok, video} = Videos.create(%{prompt: "Tea"}, "test")
    video
  end

  defp succeeded_video(dir) do
    video = queued_video()
    path = Path.join(dir, video.id <> ".mp4")
    File.write!(path, @bytes)
    spec = %{"title" => "Tea", "scenes" => [%{"duration_ms" => 3_000}]}

    {:ok, video} =
      Videos.succeed(video, %{id: video.id, spec: spec, output: path, warnings: ["a warning"]})

    video
  end

  describe "POST /api/videos" do
    test "queues a job, starts it, and answers 202 with where to look", %{conn: conn} do
      conn =
        post(conn, ~p"/api/videos", %{
          "prompt" => "Why tea is good",
          "target_duration_ms" => 30_000
        })

      assert %{"data" => %{"id" => id, "status" => "queued", "video_url" => nil} = data} =
               json_response(conn, 202)

      assert data["brief"] == %{"prompt" => "Why tea is good", "target_duration_ms" => 30_000}
      assert get_resp_header(conn, "location") == ["/api/videos/#{id}"]

      assert_received {:runner_started, ^id}
      assert Videos.get(id).status == "queued"
    end

    test "keeps the profile, and only the brief fields it knows", %{conn: conn} do
      conn =
        post(conn, ~p"/api/videos", %{
          "prompt" => "Tea",
          "tone" => "calm",
          "profile" => "free",
          "admin" => true
        })

      assert %{"data" => %{"id" => id, "brief" => brief, "profile" => "free"}} =
               json_response(conn, 202)

      assert brief == %{"prompt" => "Tea", "tone" => "calm"}
      assert Videos.get(id).profile == "free"
    end

    test "422 with every problem, and nothing is created or started", %{conn: conn} do
      conn = post(conn, ~p"/api/videos", %{"prompt" => "  ", "target_duration_ms" => 10})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert "prompt must not be blank" in errors
      assert "target_duration_ms must be between 5000 and 180000" in errors

      assert Videos.list() == []
      refute_received {:runner_started, _}
    end

    test "a request with no prompt is 422", %{conn: conn} do
      conn = post(conn, ~p"/api/videos", %{})

      assert %{"errors" => ["prompt is required"]} = json_response(conn, 422)
    end

    test "503 when the runner cannot start the job", %{conn: conn} do
      Application.put_env(:retake, :video_runner, RefusingRunner)

      conn = post(conn, ~p"/api/videos", %{"prompt" => "Tea"})

      assert %{"errors" => ["could not start the video"]} = json_response(conn, 503)
    end
  end

  describe "GET /api/videos/:id" do
    test "shows the job, with its spec once it has one", %{conn: conn, tmp_dir: dir} do
      video = succeeded_video(dir)

      data = conn |> get(~p"/api/videos/#{video.id}") |> json_response(200) |> Map.fetch!("data")

      assert %{"id" => _, "status" => "succeeded", "title" => "Tea", "duration_ms" => 3_000} =
               data

      assert data["video_url"] == "/api/videos/#{video.id}/file"
      assert data["warnings"] == ["a warning"]
      assert data["spec"]["title"] == "Tea"
      assert data["error"] == nil
    end

    test "shows progress and a failure's error", %{conn: conn} do
      video = queued_video()

      {:ok, video} =
        Videos.update_progress(video, %{"current" => %{"step" => "stock", "scene" => 2}})

      {:ok, _} =
        Videos.fail(video, %{step: :stock, scene: 2, reason: {:invalid_input, "no footage"}})

      data = conn |> get(~p"/api/videos/#{video.id}") |> json_response(200) |> Map.fetch!("data")

      assert data["status"] == "failed"
      assert data["video_url"] == nil
      assert data["error"] == %{"step" => "stock", "scene" => 2, "message" => "no footage"}
      assert data["progress"]["current"] == %{"step" => "stock", "scene" => 2}
    end

    test "404 for an unknown id", %{conn: conn} do
      assert %{"errors" => ["video not found"]} =
               conn |> get(~p"/api/videos/v-0000000000") |> json_response(404)
    end
  end

  describe "GET /api/videos" do
    test "is empty when there are no jobs", %{conn: conn} do
      assert %{"data" => []} = conn |> get(~p"/api/videos") |> json_response(200)
    end

    test "lists the jobs without their spec", %{conn: conn, tmp_dir: dir} do
      video = succeeded_video(dir)

      assert %{"data" => [listed]} = conn |> get(~p"/api/videos") |> json_response(200)

      assert listed["id"] == video.id
      assert listed["status"] == "succeeded"
      refute Map.has_key?(listed, "spec")
    end

    test "?limit= caps the list; a bad limit means the default", %{conn: conn} do
      for _ <- 1..3, do: queued_video()

      assert %{"data" => two} = conn |> get(~p"/api/videos?limit=2") |> json_response(200)
      assert length(two) == 2

      assert %{"data" => three} = conn |> get(~p"/api/videos?limit=lots") |> json_response(200)
      assert length(three) == 3
    end
  end

  describe "GET /api/videos/:id/file" do
    test "sends the whole MP4 and says a player may ask for ranges", %{conn: conn, tmp_dir: dir} do
      video = succeeded_video(dir)

      conn = get(conn, ~p"/api/videos/#{video.id}/file")

      assert response(conn, 200) == @bytes
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "?download=1 asks the browser to save it", %{conn: conn, tmp_dir: dir} do
      video = succeeded_video(dir)

      conn = get(conn, ~p"/api/videos/#{video.id}/file?download=1")

      assert response(conn, 200) == @bytes

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="#{video.id}.mp4")
             ]
    end

    test "does not mind what a player sends in Accept", %{conn: conn, tmp_dir: dir} do
      video = succeeded_video(dir)

      conn =
        conn |> put_req_header("accept", "video/mp4") |> get(~p"/api/videos/#{video.id}/file")

      assert response(conn, 200) == @bytes
    end

    for {header, status, body, content_range} <- [
          {"bytes=0-4", 206, "01234", "bytes 0-4/20"},
          {"bytes=5-", 206, "56789abcdefghij", "bytes 5-19/20"},
          {"bytes=-5", 206, "fghij", "bytes 15-19/20"},
          {"bytes=15-100", 206, "fghij", "bytes 15-19/20"},
          {"bytes=-100", 206, "0123456789abcdefghij", "bytes 0-19/20"},
          {"bytes=19-19", 206, "j", "bytes 19-19/20"}
        ] do
      test "Range #{header} sends #{status} with #{content_range}", %{conn: conn, tmp_dir: dir} do
        video = succeeded_video(dir)

        conn =
          conn
          |> put_req_header("range", unquote(header))
          |> get(~p"/api/videos/#{video.id}/file")

        assert response(conn, unquote(status)) == unquote(body)
        assert get_resp_header(conn, "content-range") == [unquote(content_range)]
        assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      end
    end

    for header <- ["bytes=20-", "bytes=25-30", "bytes=-0"] do
      test "Range #{header} is 416 and says how long the file is", %{conn: conn, tmp_dir: dir} do
        video = succeeded_video(dir)

        conn =
          conn
          |> put_req_header("range", unquote(header))
          |> get(~p"/api/videos/#{video.id}/file")

        assert response(conn, 416) == ""
        assert get_resp_header(conn, "content-range") == ["bytes */20"]
      end
    end

    for header <- ["bytes=0-4,10-14", "bytes=abc", "items=0-4", "bytes=9-3", "bytes=-"] do
      test "Range #{header} is ignored: the whole file is sent", %{conn: conn, tmp_dir: dir} do
        video = succeeded_video(dir)

        conn =
          conn
          |> put_req_header("range", unquote(header))
          |> get(~p"/api/videos/#{video.id}/file")

        assert response(conn, 200) == @bytes
        assert get_resp_header(conn, "content-range") == []
      end
    end

    test "409 until the job has succeeded", %{conn: conn} do
      video = queued_video()

      assert %{"errors" => ["the video is not ready (queued)"]} =
               conn |> get(~p"/api/videos/#{video.id}/file") |> json_response(409)
    end

    test "404 for an unknown id", %{conn: conn} do
      assert %{"errors" => ["video not found"]} =
               conn |> get(~p"/api/videos/v-0000000000/file") |> json_response(404)
    end

    test "404 when the file was deleted from the disk", %{conn: conn, tmp_dir: dir} do
      video = succeeded_video(dir)
      File.rm!(video.output_path)

      assert %{"errors" => ["the video file is gone"]} =
               conn |> get(~p"/api/videos/#{video.id}/file") |> json_response(404)
    end
  end
end
