defmodule Retake.CLI do
  @moduledoc """
  What the `mix retake.*` tasks share: starting only the services they need, and
  describing an error in plain words (what went wrong, and what to do about it).
  """

  alias Retake.Providers.Usage

  @doc """
  Starts what a provider call needs: the HTTP and JSON-schema libraries and the usage
  counters. Not the whole app: these tasks need no database or web server. Call after
  `Mix.Task.run("app.config")`.
  """
  @spec start_services() :: :ok
  def start_services do
    for app <- [:req, :jsv], do: {:ok, _} = Application.ensure_all_started(app)

    case Usage.start_link(name: Usage) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "The default providers file, `config/providers.toml` above the `api/` directory."
  @spec default_config_path() :: Path.t()
  def default_config_path, do: Path.expand("../config/providers.toml")

  @doc "The project root: the directory above the one holding the providers file."
  @spec project_root(Path.t()) :: Path.t()
  def project_root(config_path),
    do: config_path |> Path.expand() |> Path.dirname() |> Path.dirname()

  @doc """
  Inside WSL, the path at which Windows can open a Linux file (`\\\\wsl$\\<distro>\\...`);
  `nil` elsewhere.
  """
  @spec windows_path(Path.t()) :: String.t() | nil
  def windows_path(file) do
    if distro = System.get_env("WSL_DISTRO_NAME") do
      "\\\\wsl$\\#{distro}" <> String.replace(file, "/", "\\")
    end
  end

  @doc "An error from the config loader, a pipeline step or the provider layer, in words."
  @spec describe(term(), Path.t() | nil) :: String.t()
  def describe([%{path: _, message: _} | _] = errors, path) do
    lines = Enum.map_join(errors, "\n", fn e -> "  #{e.path}: #{e.message}" end)

    hint =
      if path && not File.exists?(path),
        do:
          "\nCopy config/providers.example.toml to config/providers.toml (`just setup` does it).",
        else: ""

    "cannot use #{path}:\n#{lines}#{hint}"
  end

  def describe({:unknown_profile, name}, _path), do: "unknown profile #{inspect(name)}"

  def describe({:invalid_brief, problems}, _path),
    do: "invalid request: " <> Enum.join(problems, "; ")

  def describe({:script_invalid, %{attempts: attempts, errors: errors}}, _path) do
    "the model did not produce a valid script after #{attempts} attempt(s):\n" <>
      Enum.map_join(errors, "\n", &"  - #{&1}")
  end

  def describe({:no_stock_found, queries}, _path) do
    "no stock footage or photo found for: " <> Enum.map_join(queries, ", ", &inspect/1)
  end

  # A failed render: `Retake.Render` errors are maps with a message.
  def describe(%{kind: kind, message: message}, _path), do: "#{kind}: #{message}"

  def describe({:spec_invalid, errors}, _path) do
    "the assembled spec is invalid (a bug in the pipeline):\n" <>
      Enum.map_join(errors, "\n", fn e -> "  #{e.path}: #{e.message}" end)
  end

  def describe({:exception, message}, _path), do: "unexpected error: #{message}"
  def describe({:invalid_input, message}, _path), do: message

  def describe({:all_providers_failed, attempts}, _path) do
    "no provider could answer:\n" <>
      Enum.map_join(attempts, "\n", fn %{provider: provider, reason: reason} ->
        "  #{provider}: #{reason(reason)}"
      end)
  end

  def describe({:budget_exceeded, scope}, _path), do: "the #{scope} budget is spent"
  def describe(other, _path), do: "failed: #{inspect(other)}"

  defp reason({:missing_env, variable}), do: "no API key: export #{variable}=..."

  defp reason({:http, status, message}) when status in [401, 403] do
    "HTTP #{status}: the service rejected the API key (#{message}); check that it is current and exported whole"
  end

  defp reason({:http, status, message}), do: "HTTP #{status}: #{message}"

  defp reason({:transport, why}),
    do: "could not reach the service (#{inspect(why)}); is it running?"

  defp reason({:rate_limited, window, ms}),
    do: "rate limit for the #{window} reached; try again in #{div(ms, 1000)} s"

  defp reason({:bad_provider_config, message}), do: message
  defp reason({:bad_request, message}), do: "bad request: #{message}"
  defp reason({:unknown_adapter, name}), do: "no adapter named #{inspect(name)}"

  defp reason({:too_large, size, max}),
    do: "the file is #{size} bytes, over the #{max} byte limit"

  defp reason({:invalid_result, %{errors: errors}}),
    do: "invalid reply: " <> Enum.join(errors, "; ")

  defp reason(other), do: inspect(other)
end
