defmodule Retake.Videos.Runner do
  @moduledoc """
  Runs a video job in the background: builds a client for the job's profile, runs
  `Retake.Pipeline`, and keeps the row and the watchers up to date.

  The pipeline runs in its own (unlinked) task and its events arrive here, so this one process
  does every database write: no two scenes ever write the row at once, and a crash in the
  pipeline becomes a failed job instead of taking this process down. Every event is broadcast;
  the row is written on each event except render progress, which is written at most every 5%.

  Two settings (`config :retake, ...`): `:providers_config` (the providers file) and
  `:output_dir` (where MP4s go); `:client_builder` (a function from a video to
  `{:ok, client}` or `{:error, reason}`) replaces how the client is made, for tests.
  """

  alias Retake.Pipeline
  alias Retake.Providers.Client
  alias Retake.Videos
  alias Retake.Videos.{Progress, Video}

  # Wait up to this long, in total, for a free service's rate limit to clear.
  @max_wait_ms 120_000

  @doc "Starts the job in the background."
  @spec start(Video.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Video{id: id}),
    do: Task.Supervisor.start_child(Retake.TaskSupervisor, fn -> run(id) end)

  @doc false
  def default_client(%Video{} = video) do
    Client.from_file(Application.fetch_env!(:retake, :providers_config),
      profile: video.profile,
      video_id: video.id,
      max_wait_ms: @max_wait_ms
    )
  end

  # --- the job -----------------------------------------------------------------------------

  defp run(id) do
    video = Videos.get(id)
    {:ok, video} = Videos.mark_running(video)
    Videos.broadcast(id, {:video_status, "running"})

    case build_client(video) do
      {:ok, client} -> execute(video, client)
      {:error, reason} -> finish_failed(new_state(video), %{step: :setup, scene: nil, reason: reason})
    end
  end

  defp build_client(video) do
    builder = Application.get_env(:retake, :client_builder, &default_client/1)
    builder.(video)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  defp execute(video, client) do
    runner = self()

    task =
      Task.Supervisor.async_nolink(Retake.TaskSupervisor, fn ->
        Pipeline.run(client, brief(video),
          video_id: video.id,
          output: Path.join(Application.fetch_env!(:retake, :output_dir), "#{video.id}.mp4"),
          on_event: fn event -> send(runner, {:pipeline_event, event}) end
        )
      end)

    watch(new_state(video), task)
  end

  # `video` is what the database holds; `progress` is the latest, which may be ahead of it
  # (render progress is not written on every event); `saved` is the render percent last written.
  defp new_state(video), do: %{video: video, progress: video.progress, saved: 0}

  defp brief(%Video{brief: stored}) do
    for key <- ~w(prompt target_duration_ms language tone audience)a,
        value = Map.get(stored, Atom.to_string(key)),
        into: %{},
        do: {key, value}
  end

  # Receives pipeline events until the task answers (or dies).
  defp watch(state, %Task{ref: ref} = task) do
    receive do
      {:pipeline_event, event} ->
        state |> handle_event(event) |> watch(task)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        state |> drain_events() |> finish(result)

      {:DOWN, ^ref, :process, _pid, reason} ->
        state
        |> drain_events()
        |> finish_failed(%{
          step: :pipeline,
          scene: nil,
          reason: {:exception, "the pipeline crashed: " <> crash_message(reason)}
        })
    end
  end

  # A task that raised exits with `{error, stacktrace}`; say what the error was, without the stacktrace.
  defp crash_message({reason, [_ | _] = stacktrace}) do
    :error |> Exception.normalize(reason, stacktrace) |> Exception.message()
  end

  defp crash_message(reason), do: inspect(reason)

  # Events sent just before the answer may still be in the mailbox.
  defp drain_events(state) do
    receive do
      {:pipeline_event, event} -> state |> handle_event(event) |> drain_events()
    after
      0 -> state
    end
  end

  defp handle_event(%{video: video} = state, event) do
    Videos.broadcast(video.id, {:video_event, Progress.event_json(event)})
    state = %{state | progress: Progress.record(state.progress, event)}

    case persist?(event, state.saved) do
      {true, percent} -> save_progress(%{state | saved: percent})
      false -> state
    end
  end

  defp save_progress(%{video: video, progress: progress} = state) do
    {:ok, video} = Videos.update_progress(video, progress)
    %{state | video: video}
  end

  # Everything is written, except render progress: that only every 5%.
  defp persist?(%{status: :progress, done: done, total: total}, saved) when total > 0 do
    percent = div(done * 20, total) * 5
    if percent > saved, do: {true, percent}, else: false
  end

  defp persist?(_event, saved), do: {true, saved}

  # The last progress is written with the end, even if it was the kind not written on every event.
  defp finish(state, {:ok, result}) do
    {:ok, video} = state |> save_progress() |> Map.fetch!(:video) |> Videos.succeed(result)
    Videos.broadcast(video.id, {:video_status, "succeeded"})
    video
  end

  defp finish(state, {:error, failure}), do: finish_failed(state, failure)

  defp finish_failed(state, failure) do
    {:ok, video} = state |> save_progress() |> Map.fetch!(:video) |> Videos.fail(failure)
    Videos.broadcast(video.id, {:video_status, "failed"})
    video
  end
end
