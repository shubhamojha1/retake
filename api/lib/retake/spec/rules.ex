defmodule Retake.Spec.Rules do
  @moduledoc """
  Semantic rules the JSON Schema cannot express (`spec/SPEC.md`, "Checks beyond
  the JSON Schema"). Assumes the shape is already valid.

  Implemented: asset ids exist, voice-over fits its scene, transition shorter
  than both neighbouring scenes, words in order and inside the audio. The other
  rules are listed under F01 `deferred_rules` in `features.json`.
  """

  import Retake.Spec, only: [error: 3]

  @spec check(Retake.Spec.t()) :: [Retake.Spec.error()]
  def check(spec) do
    asset_not_found(spec) ++
      voiceover_too_long(spec) ++
      transition_too_long(spec) ++
      word_errors(spec)
  end

  defp indexed_scenes(spec), do: Enum.with_index(spec["scenes"])

  defp audio_ms(spec, asset_id), do: get_in(spec, ["assets", asset_id, "media", "duration_ms"])

  # Every asset id used by a scene or the music track must exist in `assets`.
  defp asset_not_found(spec) do
    scene_refs =
      for {scene, i} <- indexed_scenes(spec),
          ref <-
            [{"/scenes/#{i}/visual/asset", scene["visual"]["asset"]}] ++ voiceover_ref(scene, i) do
        ref
      end

    music_ref =
      case spec["music"] do
        %{"asset" => id} -> [{"/music/asset", id}]
        _ -> []
      end

    for {path, id} <- scene_refs ++ music_ref, not is_map_key(spec["assets"], id) do
      error(path, :asset_not_found, "asset #{inspect(id)} is not defined in assets")
    end
  end

  defp voiceover_ref(%{"voiceover" => %{"asset" => id}}, i),
    do: [{"/scenes/#{i}/voiceover/asset", id}]

  defp voiceover_ref(_scene, _i), do: []

  # offset_ms + voice-over length must fit inside the scene, so speech is never cut off.
  defp voiceover_too_long(spec) do
    for {scene, i} <- indexed_scenes(spec),
        %{"asset" => id, "offset_ms" => offset} <- [scene["voiceover"]],
        length when is_integer(length) <- [audio_ms(spec, id)],
        offset + length > scene["duration_ms"] do
      error(
        "/scenes/#{i}/voiceover",
        :voiceover_too_long,
        "voice-over needs #{offset + length} ms (offset #{offset} + audio #{length}) " <>
          "but the scene is #{scene["duration_ms"]} ms"
      )
    end
  end

  # A transition overlaps its neighbours, so it must be shorter than both.
  defp transition_too_long(spec) do
    for [{previous, _}, {scene, i}] <- Enum.chunk_every(indexed_scenes(spec), 2, 1, :discard),
        %{"duration_ms" => length} <- [scene["transition_in"]],
        shortest = min(previous["duration_ms"], scene["duration_ms"]),
        length >= shortest do
      error(
        "/scenes/#{i}/transition_in/duration_ms",
        :transition_too_long,
        "transition of #{length} ms must be shorter than the neighbouring scenes (#{shortest} ms)"
      )
    end
  end

  # Words must be in order, not overlap, and end inside the voice-over audio.
  defp word_errors(spec) do
    for {scene, i} <- indexed_scenes(spec),
        %{"asset" => id, "words" => words} <- [scene["voiceover"]],
        problem <- word_errors(words, audio_ms(spec, id), "/scenes/#{i}/voiceover/words") do
      problem
    end
  end

  defp word_errors(words, audio_ms, base) do
    indexed = Enum.with_index(words)

    out_of_order =
      for [{previous, _}, {word, j}] <- Enum.chunk_every(indexed, 2, 1, :discard),
          word["start_ms"] < previous["end_ms"] do
        error(
          "#{base}/#{j}",
          :words_out_of_order,
          "word #{inspect(word["text"])} starts at #{word["start_ms"]} ms, " <>
            "before the previous word ends at #{previous["end_ms"]} ms"
        )
      end

    past_end =
      for {word, j} <- indexed, is_integer(audio_ms), word["end_ms"] > audio_ms do
        error(
          "#{base}/#{j}",
          :word_past_audio_end,
          "word #{inspect(word["text"])} ends at #{word["end_ms"]} ms but the audio is #{audio_ms} ms"
        )
      end

    out_of_order ++ past_end
  end
end
