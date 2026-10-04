defmodule RetakeWeb.VideoController do
  @moduledoc """
  The video API.

    * `POST /api/videos` - ask for a video: `{"prompt": "...", "target_duration_ms": 45000,
      "language": "en", "tone": "...", "audience": "...", "profile": "free"}`. Only `prompt` is
      needed. Answers `202` with the new job (it is made in the background), `422` when the
      request is not valid.
    * `GET /api/videos/:id` - the job: status, progress, warnings, error, the spec once there is one.
    * `GET /api/videos` - the latest jobs (`?limit=`, default 20, at most 100).
    * `GET /api/videos/:id/file` - the MP4, when the job is done: `409` before, `404` if the
      file is gone. Supports `Range` (a player can seek); `?download=1` asks the browser to save it.

  Which runner starts the job is `config :retake, :video_runner` (default `Retake.Videos.Runner`).
  """

  use RetakeWeb, :controller

  alias Retake.Pipeline.Script
  alias Retake.Videos

  @default_limit 20
  @max_limit 100

  def create(conn, params) do
    brief = brief(params)

    with {:ok, _brief} <- Script.normalize_brief(brief),
         {:ok, video} <- Videos.create(brief, profile(params)),
         {:ok, _pid} <- runner().start(video) do
      conn
      |> put_status(:accepted)
      |> put_resp_header("location", ~p"/api/videos/#{video.id}")
      |> render(:show, video: video)
    else
      {:error, {:invalid_brief, problems}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: problems})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{errors: ["could not start the video"]})
    end
  end

  def show(conn, %{"id" => id}) do
    case Videos.get(id) do
      nil -> not_found(conn)
      video -> render(conn, :show, video: video)
    end
  end

  def index(conn, params) do
    render(conn, :index, videos: Videos.list(limit(params)))
  end

  def file(conn, %{"id" => id} = params) do
    with %{status: "succeeded", output_path: path} <- Videos.get(id) || :missing,
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      conn
      |> put_resp_content_type("video/mp4", nil)
      |> put_resp_header("accept-ranges", "bytes")
      |> disposition(id, params)
      |> send_range(path, size)
    else
      :missing ->
        not_found(conn)

      %{status: status} ->
        conn |> put_status(:conflict) |> json(%{errors: ["the video is not ready (#{status})"]})

      {:error, _} ->
        not_found(conn, "the video file is gone")
    end
  end

  # --- the request -------------------------------------------------------------------------

  # Only the brief fields we know; anything else in the body is ignored.
  defp brief(params) do
    for key <- ~w(prompt target_duration_ms language tone audience)a,
        value = params[Atom.to_string(key)],
        into: %{},
        do: {key, value}
  end

  defp profile(%{"profile" => profile}) when is_binary(profile) and profile != "", do: profile
  defp profile(_params), do: nil

  defp limit(%{"limit" => limit}) do
    case Integer.parse(to_string(limit)) do
      {n, ""} when n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp limit(_params), do: @default_limit

  defp runner, do: Application.get_env(:retake, :video_runner, Retake.Videos.Runner)

  defp not_found(conn, message \\ "video not found") do
    conn |> put_status(:not_found) |> json(%{errors: [message]})
  end

  # --- the file ----------------------------------------------------------------------------

  defp disposition(conn, id, %{"download" => download}) when download in ["1", "true"],
    do: put_resp_header(conn, "content-disposition", ~s(attachment; filename="#{id}.mp4"))

  defp disposition(conn, _id, _params), do: conn

  defp send_range(conn, path, size) do
    case range(get_req_header(conn, "range"), size) do
      :full ->
        send_file(conn, 200, path)

      {:partial, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # One range of bytes: `bytes=0-99`, `bytes=100-` (to the end), `bytes=-500` (the last 500).
  # A header that is not one range (several ranges, nonsense) is ignored: the whole file is sent.
  defp range([header], size) do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, String.trim(header)) do
      [_, "", ""] ->
        :full

      [_, "", count] ->
        last_bytes(String.to_integer(count), size)

      [_, first, ""] ->
        from(String.to_integer(first), size - 1, size)

      [_, first, last] ->
        from(String.to_integer(first), min(String.to_integer(last), size - 1), size)

      nil ->
        :full
    end
  end

  defp range(_none_or_many, _size), do: :full

  defp last_bytes(0, _size), do: :unsatisfiable
  defp last_bytes(count, size), do: {:partial, max(size - count, 0), size - 1}

  defp from(first, _last, size) when first >= size, do: :unsatisfiable
  defp from(first, last, _size) when first > last, do: :full
  defp from(first, last, _size), do: {:partial, first, last}
end
