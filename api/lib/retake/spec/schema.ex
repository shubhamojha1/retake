defmodule Retake.Spec.Schema do
  @moduledoc """
  Shape check: validates a decoded spec against `spec/video.schema.json`
  (JSON Schema draft 2020-12, via `JSV`). The schema is built once, at compile
  time.
  """

  import Retake.Spec, only: [error: 3]

  @schema_path Path.expand("../../../../spec/video.schema.json", __DIR__)
  @external_resource @schema_path
  @root @schema_path |> File.read!() |> Jason.decode!() |> JSV.build!()

  @spec validate(term()) :: :ok | {:error, [Retake.Spec.error()]}
  def validate(spec) do
    case JSV.validate(spec, @root, cast: false) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        # min_error_level 10 keeps the causes and drops "property X did not conform" wrappers
        %{details: units} = JSV.normalize_error(e, min_error_level: 10)
        {:error, units |> Enum.flat_map(&unit_errors/1) |> Enum.uniq()}
    end
  end

  defp unit_errors(%{instanceLocation: location, errors: errors}) do
    Enum.flat_map(errors, &keyword_errors(pointer(location), &1))
  end

  # oneOf: report the causes nested inside, not the summary line.
  defp keyword_errors(_path, %{details: units}), do: Enum.flat_map(units, &unit_errors/1)

  # JSV reports these at the parent and names the property only in the message
  # ("properties 'a' and 'b' are required"). Point at each named property instead.
  # ponytail: parses the message; switch to raw JSV errors if the wording ever changes.
  defp keyword_errors(path, %{kind: kind, message: message})
       when kind in [:required, :additionalProperties] do
    for [_, name] <- Regex.scan(~r/'([^']+)'/, message) do
      error(path <> "/" <> escape(name), :schema, message)
    end
  end

  defp keyword_errors(path, %{message: message}), do: [error(path, :schema, message)]

  # JSV locations look like "#" (root) or "#/output/fps"; a JSON Pointer drops the "#".
  defp pointer("#" <> pointer), do: pointer

  defp escape(name), do: name |> String.replace("~", "~0") |> String.replace("/", "~1")
end
