defmodule RetakeWeb.VideoJSON do
  @moduledoc """
  A video job as JSON. The list leaves out the spec (it is big); one video carries it, so a
  page can show the script and the credits.
  """

  use RetakeWeb, :verified_routes

  alias Retake.Videos.Video

  def index(%{videos: videos}), do: %{data: Enum.map(videos, &summary/1)}

  def show(%{video: video}), do: %{data: Map.put(summary(video), :spec, video.spec)}

  defp summary(%Video{} = video) do
    %{
      id: video.id,
      status: video.status,
      brief: video.brief,
      profile: video.profile,
      title: video.title,
      progress: video.progress,
      duration_ms: video.duration_ms,
      warnings: video.warnings,
      error: video.error,
      video_url: if(video.status == "succeeded", do: ~p"/api/videos/#{video.id}/file"),
      inserted_at: video.inserted_at,
      updated_at: video.updated_at
    }
  end
end
