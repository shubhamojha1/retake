defmodule Mix.Tasks.Retake.Script do
  @shortdoc "Writes a video script for a topic with the configured LLM"

  @moduledoc """
  Runs the script step of the pipeline for real: your topic goes to the LLM of the
  chosen profile and the title and scenes come back.

      mix retake.script "why tea is good for you"
      mix retake.script --seconds 30 --tone playful --profile dev "how a battery works"

  Needs `config/providers.toml` (`just setup` copies the example) and the API key of
  the LLM provider in your environment, for the default profile `GROQ_API_KEY`:

      export GROQ_API_KEY=...

  Options:

    * `--profile NAME`   provider profile (default: `RETAKE_PROFILE`, else the file's default)
    * `--seconds N`      target length in seconds (default 45)
    * `--language CODE`  narration language, e.g. `en` or `pt-BR` (default `en`)
    * `--tone TEXT`, `--audience TEXT`
    * `--config PATH`    providers file (default `../config/providers.toml`)
    * `--json`           print the script as JSON

  A repeated request is answered from the cache in `.retake/cache` and costs nothing.
  """

  use Mix.Task

  alias Retake.Pipeline.Script
  alias Retake.Providers
  alias Retake.Providers.{Client, Usage}

  @switches [
    profile: :string,
    seconds: :integer,
    language: :string,
    tone: :string,
    audience: :string,
    config: :string,
    json: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or words == [] do
      Mix.raise(
        ~s|usage: mix retake.script [options] "your topic"   (see mix help retake.script)|
      )
    end

    # Load and compile, but do not start the whole app: this needs no database or web server.
    Mix.Task.run("app.config")
    for app <- [:req, :jsv], do: {:ok, _} = Application.ensure_all_started(app)
    {:ok, _usage} = Usage.start_link(name: Usage)

    path = opts[:config] || Path.expand("../config/providers.toml")

    case Client.from_file(path, profile: opts[:profile]) do
      {:ok, client} -> generate(client, words, opts)
      {:error, reason} -> Mix.raise(describe(reason, path))
    end
  end

  defp generate(client, words, opts) do
    brief =
      %{
        prompt: Enum.join(words, " "),
        language: opts[:language],
        tone: opts[:tone],
        audience: opts[:audience],
        target_duration_ms: opts[:seconds] && opts[:seconds] * 1000
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, providers} = Providers.resolve(client.config, client.profile, :llm)
    names = Enum.map_join(providers, ", then ", & &1.name)
    Mix.shell().info("profile #{client.profile}, LLM: #{names}")

    case Script.generate(client, brief) do
      {:ok, script} -> print(script, opts[:json])
      {:error, reason} -> Mix.raise(describe(reason, nil))
    end
  end

  # --- output --------------------------------------------------------------------------

  defp print(script, true) do
    json = %{"title" => script.title, "scenes" => Enum.map(script.scenes, &scene_json/1)}
    Mix.shell().info(Jason.encode!(json, pretty: true))
  end

  defp print(script, _json) do
    shell = Mix.shell()
    shell.info("\n#{script.title}\n")

    for {scene, number} <- Enum.with_index(script.scenes, 1) do
      shell.info("#{number}. #{scene.narration}")
      shell.info("   visual: #{scene.visual_query}")
      if scene.on_screen_text, do: shell.info("   on screen: #{scene.on_screen_text}")
    end

    for warning <- script.warnings, do: shell.info("\nwarning: #{warning}")

    shell.info(
      if script.cached, do: "\n(answered from the cache: no provider was called)", else: ""
    )
  end

  defp scene_json(scene) do
    base = %{"narration" => scene.narration, "visual_query" => scene.visual_query}
    if scene.on_screen_text, do: Map.put(base, "on_screen_text", scene.on_screen_text), else: base
  end

  # --- errors, in words -------------------------------------------------------------------

  defp describe([%{path: _, message: _} | _] = errors, path) do
    lines = Enum.map_join(errors, "\n", fn e -> "  #{e.path}: #{e.message}" end)

    hint =
      if path && not File.exists?(path),
        do:
          "\nCopy config/providers.example.toml to config/providers.toml (`just setup` does it).",
        else: ""

    "cannot use #{path}:\n#{lines}#{hint}"
  end

  defp describe({:unknown_profile, name}, _path), do: "unknown profile #{inspect(name)}"

  defp describe({:invalid_brief, problems}, _path),
    do: "invalid request: " <> Enum.join(problems, "; ")

  defp describe({:script_invalid, %{attempts: attempts, errors: errors}}, _path) do
    "the model did not produce a valid script after #{attempts} attempt(s):\n" <>
      Enum.map_join(errors, "\n", &"  - #{&1}")
  end

  defp describe({:all_providers_failed, attempts}, _path) do
    "no provider could answer:\n" <>
      Enum.map_join(attempts, "\n", fn %{provider: provider, reason: reason} ->
        "  #{provider}: #{reason(reason)}"
      end)
  end

  defp describe({:budget_exceeded, scope}, _path), do: "the #{scope} budget is spent"
  defp describe(other, _path), do: "failed: #{inspect(other)}"

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
  defp reason({:unknown_adapter, name}), do: "no adapter named #{inspect(name)}"

  defp reason({:invalid_result, %{errors: errors}}),
    do: "invalid reply: " <> Enum.join(errors, "; ")

  defp reason(other), do: inspect(other)
end
