defmodule Retake.VideosTest do
  use Retake.DataCase, async: true

  alias Retake.Videos
  alias Retake.Videos.Video

  @brief %{prompt: "Why tea is good for you", target_duration_ms: 8_000}

  defp create(profile \\ "test") do
    {:ok, video} = Videos.create(@brief, profile)
    video
  end

  describe "create/2" do
    test "stores a queued job under a fresh, spec-valid id" do
      video = create("free")

      assert %Video{status: "queued", profile: "free", progress: %{}, warnings: [], error: nil} =
               video

      assert Regex.match?(~r/\Av-[0-9a-f]{10}\z/, video.id)

      assert Videos.get(video.id).brief == %{
               "prompt" => "Why tea is good for you",
               "target_duration_ms" => 8_000
             }
    end

    test "leaves out blank and missing brief fields" do
      {:ok, video} = Videos.create(%{prompt: "Tea", language: "", tone: nil, audience: "kids"})

      assert video.brief == %{"prompt" => "Tea", "audience" => "kids"}
    end
  end

  describe "get/1 and list/1" do
    test "get/1 is nil for an unknown id" do
      assert Videos.get("v-0000000000") == nil
    end

    test "list/1 returns the newest first, at most the limit" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ids =
        for age <- [30, 20, 10] do
          video = create()

          Repo.update_all(from(v in Video, where: v.id == ^video.id),
            set: [inserted_at: DateTime.add(now, -age)]
          )

          video.id
        end

      assert Enum.map(Videos.list(), & &1.id) == Enum.reverse(ids)
      assert [newest] = Videos.list(1)
      assert newest.id == List.last(ids)
    end
  end

  describe "the life of a job" do
    test "mark_running/1 and update_progress/2" do
      {:ok, video} = Videos.mark_running(create())
      assert Videos.get(video.id).status == "running"

      progress = %{"current" => %{"step" => "script", "scene" => nil}}
      {:ok, _} = Videos.update_progress(video, progress)
      assert Videos.get(video.id).progress == progress
    end

    test "succeed/2 stores the spec, title, length, file and warnings" do
      video = create()

      result = %{
        id: video.id,
        spec: %{
          "title" => "Tea",
          "scenes" => [%{"duration_ms" => 2_800}, %{"duration_ms" => 3_000}]
        },
        output: "/out/#{video.id}.mp4",
        warnings: ["captions are not rendered yet"]
      }

      {:ok, _} = Videos.succeed(video, result)
      video = Videos.get(video.id)

      assert video.status == "succeeded"
      assert video.title == "Tea"
      assert video.duration_ms == 5_800
      assert video.output_path == result.output
      assert video.spec == result.spec
      assert video.warnings == result.warnings
      assert video.error == nil
    end

    test "succeed/2 keeps a warning of any length (a provider's error text can be long)" do
      video = create()
      long = "the image could not be made (" <> String.duplicate("x", 600) <> ")"

      result = %{
        id: video.id,
        spec: %{"title" => "Tea", "scenes" => [%{"duration_ms" => 1_000}]},
        output: "/out/#{video.id}.mp4",
        warnings: [long, "short one"]
      }

      assert {:ok, _} = Videos.succeed(video, result)
      assert Videos.get(video.id).warnings == [long, "short one"]
    end

    test "fail/2 says where it failed and why, in words" do
      video = create()

      {:ok, _} = Videos.fail(video, %{step: :stock, scene: 3, reason: {:no_stock_found, ["sea"]}})

      assert %{status: "failed", error: error} = Videos.get(video.id)

      assert error == %{
               "step" => "stock",
               "scene" => 3,
               "message" => ~s(no stock footage or photo found for: "sea")
             }
    end
  end

  describe "fail_interrupted/0" do
    test "fails queued and running jobs and leaves finished ones alone" do
      queued = create()
      {:ok, running} = Videos.mark_running(create())

      {:ok, done} =
        Videos.succeed(create(), %{
          id: "x",
          spec: %{"title" => "T", "scenes" => []},
          output: "o.mp4",
          warnings: []
        })

      {:ok, failed} =
        Videos.fail(create(), %{step: :script, scene: nil, reason: {:invalid_input, "no"}})

      assert Videos.fail_interrupted() == 2

      for video <- [queued, running] do
        assert %{status: "failed", error: %{"step" => "interrupted", "message" => message}} =
                 Videos.get(video.id)

        assert message =~ "stopped"
      end

      assert Videos.get(done.id).status == "succeeded"
      assert Videos.get(failed.id).error["step"] == "script"
    end

    test "is 0 when nothing was interrupted" do
      assert Videos.fail_interrupted() == 0
    end
  end

  describe "watching" do
    test "a subscriber gets what is broadcast for its video, and only that" do
      :ok = Videos.subscribe("v-aaaaaaaaaa")

      Videos.broadcast("v-bbbbbbbbbb", {:video_status, "failed"})
      Videos.broadcast("v-aaaaaaaaaa", {:video_status, "running"})

      assert_receive {:video_status, "running"}
      refute_receive {:video_status, "failed"}, 50
    end
  end
end
