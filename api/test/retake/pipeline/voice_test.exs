defmodule Retake.Pipeline.VoiceTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Voice
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "x", fallbacks = [] }
  tts = { use = "voice", fallbacks = [] }
  stt = { use = "ears", fallbacks = [] }
  stock = { use = "x", fallbacks = [] }
  music = { use = "x", fallbacks = [] }

  [providers.x]
  capability = "any"
  adapter = "fake"

  [providers.voice]
  capability = "tts"
  adapter = "fake"
  model = "kokoro"

  [providers.ears]
  capability = "stt"
  adapter = "fake"
  model = "whisper"
  """

  @scene %{narration: "Hello there world."}

  setup %{tmp_dir: dir} do
    {:ok, config} = Config.parse(@config)

    client =
      Client.new(
        config: config,
        profile: "dev",
        storage: Local.new(Path.join(dir, "store")),
        cache_root: Path.join(dir, "cache"),
        usage: start_supervised!(Usage)
      )

    %{client: client, dir: dir}
  end

  # --- fake audio and transcripts ----------------------------------------------------------

  # A valid WAV: 24 kHz mono 16-bit, `ms` long, silent.
  defp wav(ms) do
    data = :binary.copy(<<0>>, div(ms * 48_000, 1000))

    fmt =
      "fmt " <>
        <<16::little-32, 1::little-16, 1::little-16, 24_000::little-32, 48_000::little-32,
          2::little-16, 16::little-16>>

    body = "WAVE" <> fmt <> "data" <> <<byte_size(data)::little-32>> <> data
    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end

  defp word(text, start_ms, end_ms),
    do: %{"text" => text, "start_ms" => start_ms, "end_ms" => end_ms}

  defp transcript(words),
    do:
      {:ok,
       {:json, %{"language" => "english", "duration_ms" => 2000, "text" => "", "words" => words}},
       %{}}

  @hello [word("Hello", 100, 500), word("there", 600, 900), word("world.", 1000, 1500)]

  # tts: audio of `audio_ms`; stt: `words`. Each answer may also be a result tuple.
  defp serve(tts \\ nil, stt \\ nil) do
    Process.put(:fake_adapter_answers, %{
      "voice" => tts || {:ok, {:binary, wav(2000), "wav"}, %{}},
      "ears" => stt || transcript(@hello)
    })
  end

  defp calls(acc \\ []) do
    receive do
      {:adapter_called, name, _key, request} -> calls([{name, request} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- the happy path -------------------------------------------------------------------------

  describe "generate/3" do
    test "returns the voice-over asset, its words and the scene length", %{client: client} do
      serve()

      assert {:ok, %{asset: asset, voiceover: voiceover, duration_ms: duration, warnings: []}} =
               Voice.generate(client, @scene)

      assert voiceover == %{"offset_ms" => 300, "words" => @hello}
      # 300 ms before the voice + 2000 ms of audio + 500 ms after
      assert duration == 2800
      assert asset["kind"] == "audio"

      assert asset["media"] == %{
               "duration_ms" => 2000,
               "sample_rate" => 24_000,
               "channels" => 1,
               "mime" => "audio/wav"
             }
    end

    test "the asset is stored, with its hash and provenance", %{client: client, dir: dir} do
      serve()
      {:ok, %{asset: asset}} = Voice.generate(client, @scene)

      assert "store://assets/" <> _ = asset["uri"]
      assert asset["content_hash"] == Storage.content_hash(wav(2000))
      assert Storage.fetch(Local.new(Path.join(dir, "store")), asset["uri"]) == {:ok, wav(2000)}

      assert %{
               "source" => "generated",
               "capability" => "tts",
               "provider" => "voice",
               "model" => "kokoro"
             } =
               asset["provenance"]

      assert asset["provenance"]["request"] == %{"text" => "Hello there world."}
    end

    test "sends the narration to speech, then the stored audio to the transcriber", %{
      client: client
    } do
      serve()
      {:ok, %{asset: asset}} = Voice.generate(client, @scene)

      assert calls() == [
               {"voice", %{"text" => "Hello there world."}},
               {"ears", %{"audio" => asset["uri"]}}
             ]
    end

    test "tidies whitespace in the narration before speaking it", %{client: client} do
      serve()
      {:ok, _} = Voice.generate(client, %{narration: "  Hello   there\nworld.  "})

      assert [{"voice", %{"text" => "Hello there world."}} | _] = calls()
    end

    test "offset and padding set the scene length", %{client: client} do
      serve()

      assert {:ok, %{voiceover: %{"offset_ms" => 1000}, duration_ms: 3200}} =
               Voice.generate(client, @scene, offset_ms: 1000, padding_ms: 200)
    end

    test "a repeat is answered from the cache: no provider is called", %{client: client} do
      serve()
      {:ok, first} = Voice.generate(client, @scene)
      _ = calls()

      assert {:ok, ^first} = Voice.generate(client, @scene)
      assert calls() == []
    end
  end

  describe "tidying the transcript" do
    test "overlapping words are pushed apart and never run backwards", %{client: client} do
      serve(
        nil,
        transcript([word("one", 0, 600), word("two", 400, 900), word("three", 800, 1200)])
      )

      {:ok, %{voiceover: %{"words" => words}}} = Voice.generate(client, @scene)
      assert words == [word("one", 0, 600), word("two", 600, 900), word("three", 900, 1200)]
    end

    test "words come out in order", %{client: client} do
      serve(nil, transcript([word("late", 1000, 1500), word("early", 100, 500)]))

      {:ok, %{voiceover: %{"words" => words}}} = Voice.generate(client, @scene)
      assert Enum.map(words, & &1["text"]) == ["early", "late"]
    end

    test "nothing runs past the end of the audio", %{client: client} do
      serve(
        nil,
        transcript([word("ok", 100, 500), word("over", 1900, 2600), word("gone", 2100, 2400)])
      )

      {:ok, %{voiceover: %{"words" => words}}} = Voice.generate(client, @scene)
      assert words == [word("ok", 100, 500), word("over", 1900, 2000)]
    end

    test "a word with no length gets one millisecond", %{client: client} do
      serve(nil, transcript([word("blip", 500, 500), word("next", 600, 900)]))

      {:ok, %{voiceover: %{"words" => [first, _]}}} = Voice.generate(client, @scene)
      assert first == word("blip", 500, 501)
    end
  end

  describe "warnings" do
    test "a transcript far from the narration's length is flagged", %{client: client} do
      serve(nil, transcript([word("Hello", 100, 500)]))

      assert {:ok, %{warnings: [warning]}} =
               Voice.generate(client, %{
                 narration: "One two three four five six seven eight nine ten."
               })

      assert warning =~ "1 words"
      assert warning =~ "10"
    end
  end

  describe "failures" do
    test "a blank narration is rejected before any provider is called", %{client: client} do
      assert {:error, {:invalid_scene, _}} = Voice.generate(client, %{narration: "   "})
      assert {:error, {:invalid_scene, _}} = Voice.generate(client, %{})
      assert calls() == []
    end

    test "a speech failure is reported with the provider", %{client: client} do
      serve({:error, {:transport, :econnrefused}})

      assert {:error,
              {:all_providers_failed, [%{provider: "voice", reason: {:transport, :econnrefused}}]}} =
               Voice.generate(client, @scene)

      assert [{"voice", _}] = calls()
    end

    test "audio that is not a WAV file is rejected and not cached", %{client: client, dir: dir} do
      serve({:ok, {:binary, "ID3 not a wav", "wav"}, %{}})

      assert {:error, {:all_providers_failed, [%{reason: {:invalid_result, message}}]}} =
               Voice.generate(client, @scene)

      assert message =~ "WAV"
      assert Path.wildcard(Path.join(dir, "cache/*.json")) == []
    end

    test "audio in another format is rejected", %{client: client} do
      serve({:ok, {:binary, wav(2000), "mp3"}, %{}})

      assert {:error, {:all_providers_failed, [%{reason: {:invalid_result, message}}]}} =
               Voice.generate(client, @scene)

      assert message =~ "WAV"
    end

    test "silence (almost no audio) is rejected", %{client: client} do
      serve({:ok, {:binary, wav(50), "wav"}, %{}})

      assert {:error, {:all_providers_failed, [%{reason: {:invalid_result, message}}]}} =
               Voice.generate(client, @scene)

      assert message =~ "no speech"
    end

    test "audio too long for one scene is rejected", %{client: client} do
      # a scene holds 30 s: 29.3 s of audio plus the 300 ms offset and 500 ms padding does not fit
      serve({:ok, {:binary, wav(29_300), "wav"}, %{}})

      assert {:error, {:all_providers_failed, [%{reason: {:invalid_result, message}}]}} =
               Voice.generate(client, @scene)

      assert message =~ "shorten"
    end

    test "audio that just fits is accepted", %{client: client} do
      serve({:ok, {:binary, wav(29_000), "wav"}, %{}}, transcript([word("long", 0, 29_000)]))
      assert {:ok, %{duration_ms: 29_800}} = Voice.generate(client, @scene)
    end

    test "a transcription failure is reported with the provider", %{client: client} do
      serve(nil, {:error, {:http, 429, "Rate limit reached"}})

      assert {:error,
              {:all_providers_failed,
               [%{provider: "ears", reason: {:http, 429, "Rate limit reached"}}]}} =
               Voice.generate(client, @scene)
    end

    test "a transcript with no words is rejected and not cached", %{client: client, dir: dir} do
      serve(nil, transcript([]))

      assert {:error,
              {:all_providers_failed, [%{provider: "ears", reason: {:invalid_result, message}}]}} =
               Voice.generate(client, @scene)

      assert message =~ "no words"
      # the speech was fine and is cached; the empty transcript is not
      assert length(Path.wildcard(Path.join(dir, "cache/*.json"))) == 1
    end
  end
end
