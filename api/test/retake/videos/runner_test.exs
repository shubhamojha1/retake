defmodule Retake.Videos.RunnerTest do
  @moduledoc """
  A job from queued to finished, offline, with the real renderer: the scripted stand-ins
  (`Retake.Test.ScriptedClient`) answer every provider call. Needs the debug renderer
  (`cargo build -p retake_render`, done by `just test`).
  """

  # Renders video, and the runner writes the database from its own process (shared sandbox).
  use Retake.DataCase, async: false

  import ExUnit.CaptureLog

  alias Retake.Providers.Usage
  alias Retake.Test.ScriptedClient
  alias Retake.Videos
  alias Retake.Videos.Runner

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @brief %{prompt: "Why tea is good for you", target_duration_ms: 8_000}

  setup %{tmp_dir: dir} do
    put_env(:output_dir, Path.join(dir, "out"))
    on_exit(fn -> Application.delete_env(:retake, :client_builder) end)
    :ok
  end

  # Sets an app setting for this test only.
  defp put_env(key, value) do
    previous = Application.fetch_env!(:retake, key)
    Application.put_env(:retake, key, value)
    on_exit(fn -> Application.put_env(:retake, key, previous) end)
  end

  defp use_client(dir, overrides \\ %{}) do
    client = ScriptedClient.client(dir, start_supervised!(Usage, id: make_ref()), overrides)
    Application.put_env(:retake, :client_builder, fn _video -> {:ok, client} end)
  end

  # Starts a job and watches it; returns the finished video.
  defp run_job(brief \\ @brief) do
    {:ok, video} = Videos.create(brief, "test")
    Videos.subscribe(video.id)
    {:ok, _pid} = Runner.start(video)

    assert_receive {:video_status, "running"}, 5_000
    assert_receive {:video_status, status}, 120_000
    assert status in ["succeeded", "failed"]
    Videos.get(video.id)
  end

  # The last `{:video_progress, map}` that reached the test process (nil if none did).
  defp last_progress(last \\ nil) do
    receive do
      {:video_progress, progress} -> last_progress(progress)
    after
      0 -> last
    end
  end

  describe "a job that works" do
    test "ends succeeded: the MP4 on disk, the spec, the length, the warnings", %{tmp_dir: dir} do
      use_client(dir)

      video = run_job()

      assert video.status == "succeeded"
      assert video.title == "Tea in three scenes"
      assert video.duration_ms == 8_400
      assert video.output_path == Path.join([dir, "out", video.id <> ".mp4"])
      assert File.stat!(video.output_path).size > 0
      assert video.spec["id"] == video.id
      assert Enum.any?(video.warnings, &(&1 =~ "captions"))
      assert video.error == nil
    end

    test "keeps the progress in the row: every step, every scene", %{tmp_dir: dir} do
      use_client(dir)

      %{progress: progress} = run_job()

      assert %{"status" => "done", "scenes" => 3} = progress["steps"]["script"]
      assert progress["steps"]["assemble"]["status"] == "done"
      # the render's "done" replaces its "running" entry, and does not give away the file path
      assert progress["steps"]["render"] == %{"status" => "done"}

      assert Map.keys(progress["scenes"]) |> Enum.sort() == ["1", "2", "3"]

      for {_scene, steps} <- progress["scenes"] do
        assert steps["visual"]["status"] == "done"
        assert steps["voice"]["status"] == "done"
      end

      assert progress["scenes"]["1"]["visual"]["kind"] == "video"
    end

    test "tells watchers each step, in order, before the final status", %{tmp_dir: dir} do
      use_client(dir)

      run_job()

      # everything was sent from the runner, so the mailbox is in the order it happened
      assert_received {:video_event, %{"step" => "script", "status" => "started"}}

      assert_received {:video_event,
                       %{"step" => "script", "status" => "done", "title" => "Tea in three scenes"}}

      assert_received {:video_event, %{"step" => "visual", "scene" => 2, "status" => "done"}}
      assert_received {:video_event, %{"step" => "voice", "scene" => 3, "status" => "done"}}

      assert_received {:video_event,
                       %{"step" => "render", "status" => "running", "done" => _, "total" => _}}

      assert_received {:video_event, %{"step" => "render", "status" => "done"}}
    end

    test "tells watchers the whole progress map each time it is written", %{tmp_dir: dir} do
      use_client(dir)

      run_job()

      # the first one (the script just announced)...
      assert_received {:video_progress, %{"steps" => %{"brief" => %{"status" => "started"}}}}

      # ...and the last one, sent when the job ended, is the finished state
      progress = last_progress()
      assert progress["steps"]["render"] == %{"status" => "done"}
      assert progress["steps"]["script"]["status"] == "done"
      assert Map.keys(progress["scenes"]) |> Enum.sort() == ["1", "2", "3"]
    end

    test "the script's outline is in the progress, for a page to show while scenes are made", %{
      tmp_dir: dir
    } do
      use_client(dir)

      %{progress: progress} = run_job()

      assert [%{"narration" => narration, "query" => "clip video steam"} | _] =
               progress["steps"]["script"]["outline"]

      assert is_binary(narration) and narration != ""
      assert length(progress["steps"]["script"]["outline"]) == 3
    end
  end

  describe "a job that fails" do
    test "says which step and why, and keeps what was done before", %{tmp_dir: dir} do
      use_client(dir, %{"stock" => ~s(empty_for = "sea")})

      video = run_job()

      assert video.status == "failed"
      assert %{"step" => "visual", "scene" => 3, "message" => message} = video.error
      assert message =~ "no stock footage or photo found"
      assert video.output_path == nil
      assert video.progress["steps"]["script"]["status"] == "done"
      assert %{"status" => "failed", "message" => _} = video.progress["scenes"]["3"]["visual"]
      refute Map.has_key?(video.progress["steps"], "render")
    end

    test "a script that cannot be made fails the script step", %{tmp_dir: dir} do
      use_client(dir, %{"llm" => "fail = true"})

      video = run_job()

      assert %{"step" => "script", "scene" => nil, "message" => "no provider could answer" <> _} =
               video.error

      assert video.progress["steps"]["script"]["status"] == "failed"
    end

    test "an invalid brief fails the brief step", %{tmp_dir: dir} do
      use_client(dir)

      video = run_job(%{prompt: "  "})

      assert %{"step" => "brief", "scene" => nil, "message" => "invalid request: " <> _} =
               video.error

      assert video.progress["steps"]["brief"]["status"] == "failed"
    end

    test "a client that cannot be built fails the setup step" do
      Application.put_env(:retake, :client_builder, fn _video ->
        {:error, {:unknown_profile, "nope"}}
      end)

      video = run_job()

      assert video.status == "failed"

      assert video.error == %{
               "step" => "setup",
               "scene" => nil,
               "message" => ~s(unknown profile "nope")
             }
    end

    test "a client builder that raises fails the setup step" do
      Application.put_env(:retake, :client_builder, fn _video -> raise "no config file" end)

      video = run_job()

      assert video.error == %{
               "step" => "setup",
               "scene" => nil,
               "message" => "unexpected error: no config file"
             }
    end

    test "a pipeline that crashes fails the job instead of leaving it running" do
      Application.put_env(:retake, :client_builder, fn _video -> {:ok, :not_a_client} end)

      capture_log(fn ->
        video = run_job()

        assert video.status == "failed"

        assert %{
                 "step" => "pipeline",
                 "message" => "unexpected error: the pipeline crashed: " <> detail
               } = video.error

        assert detail =~ "no function clause"
      end)
    end
  end
end
