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

  alias Retake.CLI
  alias Retake.Pipeline.Script
  alias Retake.Providers
  alias Retake.Providers.Client

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

    Mix.Task.run("app.config")
    CLI.start_services()

    path = opts[:config] || CLI.default_config_path()

    case Client.from_file(path, profile: opts[:profile]) do
      {:ok, client} -> generate(client, words, opts)
      {:error, reason} -> Mix.raise(CLI.describe(reason, path))
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
      {:error, reason} -> Mix.raise(CLI.describe(reason, nil))
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
      if scene.image_prompt, do: shell.info("   image:  #{scene.image_prompt}")
      if scene.on_screen_text, do: shell.info("   on screen: #{scene.on_screen_text}")
    end

    for warning <- script.warnings, do: shell.info("\nwarning: #{warning}")

    shell.info(
      if script.cached, do: "\n(answered from the cache: no provider was called)", else: ""
    )
  end

  defp scene_json(scene) do
    %{"narration" => scene.narration, "visual_query" => scene.visual_query}
    |> put_if("image_prompt", scene.image_prompt)
    |> put_if("on_screen_text", scene.on_screen_text)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
