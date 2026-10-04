defmodule RetakeWeb.VideoChannel do
  @moduledoc """
  Live state of one video job, for the browser. Join `video:<id>`; the channel pushes:

    * `"video"` - the whole job, as `GET /api/videos/:id` gives it (`%{data: ...}`): once after
      joining, and again whenever the job's status changes (so the finished video arrives
      with its spec and `video_url`)
    * `"progress"` - `%{progress: ...}`, the job's whole progress map (see `Retake.Videos.Progress`),
      each time the runner writes it. Replace the old one; there is nothing to merge.

  The channel's topic is also the PubSub topic `Retake.Videos` broadcasts on (D23), so the runner's
  messages arrive in `handle_info/2` with no extra subscribing. Phoenix subscribes a channel only
  after `join/3` returns, so the first snapshot is read in `:after_join`: an event may then be seen
  twice (in the snapshot and as a push), never missed.
  """

  use RetakeWeb, :channel

  alias Retake.Videos
  alias RetakeWeb.VideoJSON

  @impl true
  def join("video:" <> id, _params, socket) do
    if Videos.get(id) do
      send(self(), :after_join)
      {:ok, assign(socket, :video_id, id)}
    else
      {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket), do: {:noreply, push_video(socket)}

  def handle_info({:video_status, _status}, socket), do: {:noreply, push_video(socket)}

  def handle_info({:video_progress, progress}, socket) do
    push(socket, "progress", %{progress: progress})
    {:noreply, socket}
  end

  # One message per pipeline event: the progress pushes carry the same news, in fewer messages.
  def handle_info({:video_event, _event}, socket), do: {:noreply, socket}

  defp push_video(socket) do
    if video = Videos.get(socket.assigns.video_id) do
      push(socket, "video", VideoJSON.show(%{video: video}))
    end

    socket
  end
end
