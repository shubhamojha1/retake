defmodule Retake.Spec do
  @moduledoc """
  Loads and validates a video spec (`spec/SPEC.md`).

  Validation is two steps. First the shape is checked against
  `spec/video.schema.json` (`Retake.Spec.Schema`). Only if the shape is right do
  the semantic rules run (`Retake.Spec.Rules`), because they assume it.

  A spec stays a plain decoded map with string keys. Errors point at the
  problem with a JSON Pointer (RFC 6901), for example `/scenes/0/voiceover`.

  A spec written for an older version is migrated first (`migrate/1`), so `validate/1` and
  `load/1` return the current format.
  """

  alias Retake.Spec.{Rules, Schema}

  @current_version "0.2"

  @type t :: map()
  @type error :: %{path: String.t(), rule: atom(), message: String.t()}

  @doc "Reads a spec file, decodes the JSON, and validates it."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [error()]}
  def load(path) do
    with {:ok, body} <- read(path),
         {:ok, spec} <- decode(body) do
      validate(spec)
    end
  end

  @doc """
  Brings a spec written for an older format up to the current one: a 0.1 spec only needs its
  version changed (0.2 added an optional field). Anything else is returned as it is.
  """
  @spec migrate(term()) :: term()
  def migrate(%{"spec_version" => "0.1"} = spec),
    do: Map.put(spec, "spec_version", @current_version)

  def migrate(spec), do: spec

  @doc "Validates a decoded spec (migrated first). Returns every error found, not just the first."
  @spec validate(term()) :: {:ok, t()} | {:error, [error()]}
  def validate(spec) do
    spec = migrate(spec)

    with :ok <- Schema.validate(spec),
         [] <- Rules.check(spec) do
      {:ok, spec}
    else
      {:error, errors} -> {:error, errors}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  @doc false
  @spec error(String.t(), atom(), String.t()) :: error()
  def error(path, rule, message), do: %{path: path, rule: rule, message: message}

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error, [error("", :file, "cannot read #{path}: #{:file.format_error(reason)}")]}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, spec} -> {:ok, spec}
      {:error, %Jason.DecodeError{} = e} -> {:error, [error("", :json, Exception.message(e))]}
    end
  end
end
