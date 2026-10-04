defmodule Retake.Pipeline.Voice do
  @moduledoc """
  Step 3 of the pipeline: a scene's narration becomes a voice-over with word timings,
  and the scene gets its length.

    1. text to speech: the narration becomes a WAV file (stored, cached);
    2. its duration is read from the WAV header (`Retake.Media.Wav`);
    3. speech to text: the audio is transcribed with word timestamps (stored, cached);
    4. the words are tidied so they satisfy the spec: in order, not overlapping, each at
       least 1 ms long, none past the end of the audio;
    5. the scene length is the voice-over start offset + the audio + some padding.

  A reply that is unusable (no audio, not a WAV, too long for a scene, a transcript with
  no words) is never cached: `Retake.Providers.Client` validates before it stores.

  Returns `{:ok, %{asset: asset, voiceover: voiceover, duration_ms: ms, warnings: [..]}}`:
  `asset` is a spec asset (`kind` "audio", string keys); `voiceover` is the scene's
  `voiceover` without its `"asset"` id (the pipeline assigns ids): `%{"offset_ms", "words"}`.

  Talks to providers only through `Retake.Providers.Client`.
  """

  alias Retake.Cache.Entry
  alias Retake.Media.Wav
  alias Retake.Providers.Client
  alias Retake.Storage

  @default_offset_ms 300
  @default_padding_ms 500
  @max_scene_ms 30_000
  @min_audio_ms 200

  @type result :: %{
          asset: map(),
          voiceover: %{String.t() => term()},
          duration_ms: pos_integer(),
          warnings: [String.t()]
        }

  @doc """
  Options: `:offset_ms` (delay before the voice starts in the scene, default 300) and
  `:padding_ms` (silence after it, default 500).
  """
  @spec generate(Client.t(), %{narration: String.t()}, keyword()) ::
          {:ok, result()} | {:error, term()}
  def generate(%Client{} = client, scene, opts \\ []) do
    offset = Keyword.get(opts, :offset_ms, @default_offset_ms)
    padding = Keyword.get(opts, :padding_ms, @default_padding_ms)
    max_audio = @max_scene_ms - offset - padding

    with {:ok, text} <- narration(scene),
         {:ok, tts, ref} <- speak(client, text, max_audio),
         {:ok, info} <- audio_info(client, ref),
         {:ok, transcript} <- transcribe(client, ref) do
      words = tidy(transcript, info.duration_ms)

      {:ok,
       %{
         asset: asset(tts, ref, info),
         voiceover: %{"offset_ms" => offset, "words" => words},
         duration_ms: offset + info.duration_ms + padding,
         warnings: warnings(text, words)
       }}
    end
  end

  # --- text to speech -------------------------------------------------------------------

  defp narration(%{narration: narration}) when is_binary(narration) do
    case narration |> String.split() |> Enum.join(" ") do
      "" -> {:error, {:invalid_scene, "narration must not be blank"}}
      text -> {:ok, text}
    end
  end

  defp narration(_scene), do: {:error, {:invalid_scene, "the scene needs a narration"}}

  defp speak(client, text, max_audio) do
    case Client.call(client, :tts, %{"text" => text}, validate: &valid_audio(&1, max_audio)) do
      {:ok, %Entry{result: {:asset, ref}} = entry, _outcome} -> {:ok, entry, ref}
      {:ok, entry, _outcome} -> {:error, {:unexpected_speech_result, entry.result}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_audio({:binary, bytes, "wav"}, max_audio) do
    case Wav.info(bytes) do
      {:ok, %{duration_ms: ms}} when ms < @min_audio_ms ->
        {:error, "the audio is #{ms} ms long: no speech was produced"}

      {:ok, %{duration_ms: ms}} when ms > max_audio ->
        {:error,
         "the audio is #{ms} ms but a scene can hold #{max_audio} ms of voice-over: shorten the narration"}

      {:ok, _info} ->
        :ok

      {:error, why} ->
        {:error, "the audio is not a readable WAV file (#{why})"}
    end
  end

  defp valid_audio(_output, _max_audio),
    do: {:error, "the speech provider must return a WAV file"}

  defp audio_info(client, ref) do
    with {:ok, bytes} <- Storage.fetch(client.storage, ref.uri),
         {:ok, info} <- Wav.info(bytes) do
      {:ok, info}
    else
      {:error, reason} -> {:error, {:voice_over_unreadable, reason}}
    end
  end

  # --- speech to text -----------------------------------------------------------------------

  defp transcribe(client, ref) do
    case Client.call(client, :stt, %{"audio" => ref.uri}, validate: &valid_transcript/1) do
      {:ok, %Entry{result: {:json, %{"words" => words}}}, _outcome} -> {:ok, words}
      {:ok, entry, _outcome} -> {:error, {:unexpected_transcript, entry.result}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_transcript({:json, %{"words" => [_ | _]}}), do: :ok

  defp valid_transcript({:json, %{"words" => []}}),
    do: {:error, "no words were recognised in the voice-over"}

  defp valid_transcript(_output), do: {:error, "the transcript has no word list"}

  # Whisper's timings can overlap, run past the audio or collapse to nothing. The spec wants
  # the words in order, not overlapping, and inside the audio.
  defp tidy(words, duration_ms) do
    words
    |> Enum.sort_by(&{&1["start_ms"], &1["end_ms"]})
    |> Enum.reduce({[], 0}, fn word, {kept, floor} ->
      start = max(word["start_ms"], floor)
      stop = min(max(word["end_ms"], start + 1), duration_ms)

      if start < stop do
        {[%{"text" => word["text"], "start_ms" => start, "end_ms" => stop} | kept], stop}
      else
        {kept, floor}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # --- describing the result -------------------------------------------------------------------

  defp asset(tts, ref, info) do
    %{
      "kind" => "audio",
      "uri" => ref.uri,
      "content_hash" => ref.content_hash,
      "media" => %{
        "duration_ms" => info.duration_ms,
        "sample_rate" => info.sample_rate,
        "channels" => info.channels,
        "mime" => "audio/wav"
      },
      "provenance" => Entry.provenance(tts)
    }
  end

  # Whisper can mishear: a transcript far from the script's length is worth a look.
  defp warnings(text, words) do
    spoken = length(String.split(text))
    heard = length(words)

    if abs(spoken - heard) > max(2, spoken * 0.3) do
      ["the transcript has #{heard} words but the narration has #{spoken}: check the voice-over"]
    else
      []
    end
  end
end
