defmodule Retake.Videos.Progress do
  @moduledoc """
  The live state of a video job, built from the pipeline's events (`Retake.Pipeline`). A pure
  function over a JSON-friendly map (string keys), so it can be stored in the database as it
  is and sent to a browser:

      %{
        "current" => %{"step" => "stock", "scene" => 2},
        "steps" => %{
          "script" => %{"status" => "done", "scenes" => 5, "title" => "..."},
          "assemble" => %{"status" => "started"},
          "render" => %{"status" => "running", "done" => 120, "total" => 840}
        },
        "scenes" => %{
          "1" => %{"stock" => %{"status" => "done", "kind" => "video", "credit" => "..."},
                   "voice" => %{"status" => "done", "duration_ms" => 3800}}
        }
      }

  Statuses: `"started"`, `"running"` (render progress), `"done"`, `"failed"`. A failed entry
  carries a `"message"` in words.
  """

  alias Retake.CLI

  @doc "Records one pipeline event in a progress map."
  @spec record(map(), Retake.Pipeline.event()) :: map()
  def record(progress, %{step: step, scene: scene} = event) do
    step_name = Atom.to_string(step)
    entry = event_json(event) |> Map.drop(["step", "scene"])

    progress
    |> put_entry(step_name, scene, entry)
    |> Map.put("current", %{"step" => step_name, "scene" => scene})
  end

  @doc """
  An event as a JSON-friendly map with string keys, for the database and for browsers:
  `%{"step", "scene", "status", ...detail}`. The status `:progress` is written `"running"`, and a
  failure's `reason` becomes a `"message"`. The render's `output` (a path on the server) is left
  out: a finished video is reached by its URL.
  """
  @spec event_json(Retake.Pipeline.event()) :: map()
  def event_json(%{step: step, scene: scene, status: status} = event) do
    detail = event |> Map.drop([:step, :scene, :status, :reason, :output]) |> jsonable()

    %{"step" => Atom.to_string(step), "scene" => scene, "status" => status_name(status)}
    |> Map.merge(detail)
    |> put_message(event)
  end

  defp status_name(:progress), do: "running"
  defp status_name(status), do: Atom.to_string(status)

  defp put_message(map, %{reason: reason}), do: Map.put(map, "message", CLI.describe(reason, nil))
  defp put_message(map, _event), do: map

  defp put_entry(progress, step, nil, entry) do
    Map.update(progress, "steps", %{step => entry}, &Map.put(&1, step, entry))
  end

  defp put_entry(progress, step, scene, entry) do
    scene = Integer.to_string(scene)

    Map.update(progress, "scenes", %{scene => %{step => entry}}, fn scenes ->
      Map.update(scenes, scene, %{step => entry}, &Map.put(&1, step, entry))
    end)
  end

  defp jsonable(map), do: Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)

  defp json_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_map(value) and not is_struct(value), do: jsonable(value)
  defp json_value(value), do: inspect(value)
end
