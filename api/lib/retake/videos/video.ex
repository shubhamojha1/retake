defmodule Retake.Videos.Video do
  @moduledoc """
  One video job. `status` is `"queued"`, `"running"`, `"succeeded"` or `"failed"`.

    * `brief` - what was asked for (string keys: prompt, target_duration_ms, language, ...)
    * `progress` - the live state of the pipeline, kept by `Retake.Videos.Progress`
    * `spec` - the spec that was rendered (once the pipeline got that far)
    * `output_path` - the MP4 on disk, when succeeded
    * `warnings` - things worth a look (a short clip held on its last frame, ...)
    * `error` - when failed: `%{"step", "scene", "message"}` naming where and why
  """

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "videos" do
    field :status, :string, default: "queued"
    field :brief, :map
    field :profile, :string
    field :title, :string
    field :progress, :map, default: %{}
    field :spec, :map
    field :output_path, :string
    field :duration_ms, :integer
    field :warnings, {:array, :string}, default: []
    field :error, :map

    timestamps(type: :utc_datetime)
  end
end
