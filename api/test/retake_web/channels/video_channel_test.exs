defmodule RetakeWeb.VideoChannelTest do
  # Channel processes read the database, so the sandbox is shared (not async).
  use Retake.DataCase, async: false

  import Phoenix.ChannelTest

  alias Retake.Videos
  alias RetakeWeb.{UserSocket, VideoChannel}

  @endpoint RetakeWeb.Endpoint

  defp video do
    {:ok, video} = Videos.create(%{prompt: "Tea"}, "test")
    video
  end

  # Named so it cannot be mistaken for `Phoenix.ChannelTest.join/3` or `Ecto.Query.join/5`.
  defp join_video(id) do
    UserSocket |> socket(nil, %{}) |> subscribe_and_join(VideoChannel, "video:" <> id)
  end

  describe "join/3" do
    test "refuses a video that does not exist" do
      assert {:error, %{reason: "not_found"}} = join_video("v-0000000000")
    end

    test "pushes the whole job right after joining, in the shape of GET /api/videos/:id" do
      %{id: id} = video()

      assert {:ok, _reply, _socket} = join_video(id)

      assert_push "video", %{data: %{id: ^id, status: "queued", progress: %{}, video_url: nil}}
    end
  end

  describe "what the runner broadcasts" do
    test "a progress map is pushed whole" do
      %{id: id} = video()
      {:ok, _, _} = join_video(id)
      progress = %{"current" => %{"step" => "script", "scene" => nil}, "steps" => %{}}

      Videos.broadcast(id, {:video_progress, progress})

      assert_push "progress", %{progress: ^progress}
    end

    test "a change of status pushes the whole job again, now finished" do
      video = video()
      {:ok, _, _} = join_video(video.id)

      result = %{
        id: video.id,
        spec: %{"title" => "Tea", "scenes" => [%{"duration_ms" => 3_000}]},
        output: "/out/#{video.id}.mp4",
        warnings: []
      }

      {:ok, _} = Videos.succeed(video, result)
      Videos.broadcast(video.id, {:video_status, "succeeded"})

      assert_push "video", %{
        data: %{status: "succeeded", title: "Tea", video_url: url, spec: %{"title" => "Tea"}}
      }

      assert url == "/api/videos/#{video.id}/file"
    end

    test "per-event messages are not pushed: the progress map carries the same news" do
      %{id: id} = video()
      {:ok, _, _} = join_video(id)

      Videos.broadcast(
        id,
        {:video_event, %{"step" => "script", "scene" => nil, "status" => "started"}}
      )

      refute_push "event", _
      refute_push "progress", _
    end

    test "only the video that was joined" do
      %{id: id} = video()
      %{id: other} = video()
      {:ok, _, _} = join_video(id)

      Videos.broadcast(other, {:video_progress, %{"steps" => %{}}})

      refute_push "progress", _
    end
  end
end
