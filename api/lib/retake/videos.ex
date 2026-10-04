defmodule Retake.Videos do
  @moduledoc """
  Video jobs: the `videos` table, and the broadcasts that tell watchers (the web page) what
  happens. `Retake.Videos.Runner` runs a job and keeps its row up to date; this module is the
  data side.

  Every change a watcher cares about is broadcast on the topic `"video:<id>"` (`subscribe/1`):

      {:video_event, %{"step" => "stock", "scene" => 2, "status" => "done", ...}}  (every event)
      {:video_progress, progress}  (the whole progress map, each time it is written)
      {:video_status, "running" | "succeeded" | "failed"}
  """

  import Ecto.Query

  alias Retake.CLI
  alias Retake.Pipeline
  alias Retake.Repo
  alias Retake.Videos.Video

  @pubsub Retake.PubSub

  @doc """
  Creates a queued job for `brief` (a map with a `:prompt` and optional `:target_duration_ms`,
  `:language`, `:tone`, `:audience`). Blank and missing values are not stored.
  """
  @spec create(map(), String.t() | nil) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def create(brief, profile \\ nil) do
    stored =
      for {key, value} <- brief, value not in [nil, ""], into: %{}, do: {to_string(key), value}

    %Video{id: Pipeline.new_video_id(), status: "queued", brief: stored, profile: profile}
    |> Ecto.Changeset.change()
    |> Repo.insert()
  end

  @spec get(String.t()) :: Video.t() | nil
  def get(id), do: Repo.get(Video, id)

  @doc "The most recent jobs, newest first."
  @spec list(pos_integer()) :: [Video.t()]
  def list(limit \\ 20) do
    Repo.all(from v in Video, order_by: [desc: v.inserted_at, desc: v.id], limit: ^limit)
  end

  @spec mark_running(Video.t()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(%Video{} = video), do: save(video, %{status: "running"})

  @doc "Stores a new progress map (see `Retake.Videos.Progress`)."
  @spec update_progress(Video.t(), map()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def update_progress(%Video{} = video, progress), do: save(video, %{progress: progress})

  @doc "Marks the job succeeded with the pipeline's result (`Retake.Pipeline.run/3`)."
  @spec succeed(Video.t(), Pipeline.result()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def succeed(%Video{} = video, result) do
    duration = result.spec["scenes"] |> Enum.map(& &1["duration_ms"]) |> Enum.sum()

    save(video, %{
      status: "succeeded",
      spec: result.spec,
      title: result.spec["title"],
      output_path: result.output,
      duration_ms: duration,
      warnings: result.warnings,
      error: nil
    })
  end

  @doc "Marks the job failed. `failure` is `%{step, scene, reason}` as the pipeline returns it."
  @spec fail(Video.t(), Pipeline.failure()) :: {:ok, Video.t()} | {:error, Ecto.Changeset.t()}
  def fail(%Video{} = video, %{step: step, scene: scene, reason: reason}) do
    save(video, %{
      status: "failed",
      error: %{
        "step" => to_string(step),
        "scene" => scene,
        "message" => CLI.describe(reason, nil)
      }
    })
  end

  @doc """
  Marks every job that was queued or running as failed. Called when the app starts: a job that
  was running when the app stopped will never finish.
  """
  @spec fail_interrupted() :: non_neg_integer()
  def fail_interrupted do
    error = %{
      "step" => "interrupted",
      "scene" => nil,
      "message" => "the app stopped while this video was being made"
    }

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(from(v in Video, where: v.status in ["queued", "running"]),
        set: [status: "failed", error: error, updated_at: now]
      )

    count
  end

  # --- watching a job ----------------------------------------------------------------------

  @spec topic(String.t()) :: String.t()
  def topic(id), do: "video:#{id}"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id), do: Phoenix.PubSub.subscribe(@pubsub, topic(id))

  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(id, message), do: Phoenix.PubSub.broadcast(@pubsub, topic(id), message)

  # Not `update`: that is a macro from Ecto.Query, imported above.
  defp save(video, attrs) do
    video
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
  end
end
