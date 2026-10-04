defmodule Mix.Tasks.Retake.Voice do
  @shortdoc "Speaks a narration, transcribes it and times its words"

  @moduledoc """
  Runs the voice step of the pipeline for real: your text is spoken by the text-to-speech
  provider of the chosen profile (Kokoro, by default), the audio is transcribed with word
  timestamps (Groq's Whisper, by default), and the scene length is worked out.

      mix retake.voice "Tea is packed with antioxidants and calms the mind."

  Needs `config/providers.toml`, a text-to-speech server (the default profile expects
  Kokoro on http://localhost:8880, see `just kokoro`), and `GROQ_API_KEY` for the
  transcription.

  Options:

    * `--offset N`    milliseconds of silence before the voice starts in the scene (default 300)
    * `--padding N`   milliseconds after it (default 500)
    * `--profile NAME`, `--config PATH` as for `mix help retake.script`
    * `--json`        print the voice-over asset, the words and the scene length as JSON

  The WAV file is kept in `.retake/store`; the path is printed so you can listen to it.
  A repeated text is answered from the cache.
  """

  use Mix.Task

  alias Retake.CLI
  alias Retake.Pipeline.Voice
  alias Retake.Providers
  alias Retake.Providers.Client
  alias Retake.Storage

  @switches [
    profile: :string,
    config: :string,
    offset: :integer,
    padding: :integer,
    json: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or words == [] do
      Mix.raise(
        ~s|usage: mix retake.voice [options] "what the narrator says"   (see mix help retake.voice)|
      )
    end

    Mix.Task.run("app.config")
    CLI.start_services()

    path = opts[:config] || CLI.default_config_path()

    case Client.from_file(path, profile: opts[:profile]) do
      {:ok, client} -> speak(client, Enum.join(words, " "), opts)
      {:error, reason} -> Mix.raise(CLI.describe(reason, path))
    end
  end

  defp speak(client, text, opts) do
    {:ok, speech} = Providers.resolve(client.config, client.profile, :tts)
    {:ok, listening} = Providers.resolve(client.config, client.profile, :stt)

    Mix.shell().info(
      "profile #{client.profile}, speech: #{names(speech)}; transcription: #{names(listening)}"
    )

    voice_opts =
      [offset_ms: opts[:offset], padding_ms: opts[:padding]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Voice.generate(client, %{narration: text}, voice_opts) do
      {:ok, voice} -> print(client, voice, opts[:json])
      {:error, reason} -> Mix.raise(CLI.describe(reason, nil))
    end
  end

  defp names(providers), do: Enum.map_join(providers, ", then ", & &1.name)

  defp print(_client, voice, true) do
    json = %{
      "asset" => voice.asset,
      "voiceover" => voice.voiceover,
      "duration_ms" => voice.duration_ms
    }

    Mix.shell().info(Jason.encode!(json, pretty: true))
  end

  defp print(client, voice, _json) do
    shell = Mix.shell()
    media = voice.asset["media"]

    shell.info(
      "\nvoice-over:   #{seconds(media["duration_ms"])} s  (#{media["sample_rate"]} Hz, #{media["channels"]} channel)"
    )

    shell.info(
      "scene length: #{seconds(voice.duration_ms)} s  (voice starts at #{seconds(voice.voiceover["offset_ms"])} s)"
    )

    shell.info("stored as:    #{voice.asset["uri"]}")

    case Storage.local_path(client.storage, voice.asset["uri"]) do
      {:ok, file} ->
        shell.info("file:         #{file}")
        if windows = CLI.windows_path(file), do: shell.info("from Windows:  #{windows}")

      {:error, _} ->
        :ok
    end

    shell.info("\nwords (seconds from the start of the audio):")

    for word <- voice.voiceover["words"] do
      shell.info(
        "  #{pad(seconds(word["start_ms"]))} - #{pad(seconds(word["end_ms"]))}  #{word["text"]}"
      )
    end

    for warning <- voice.warnings, do: shell.info("\nwarning: #{warning}")
  end

  defp seconds(ms), do: Float.round(ms / 1000, 2)
  defp pad(seconds), do: seconds |> :erlang.float_to_binary(decimals: 2) |> String.pad_leading(5)
end
