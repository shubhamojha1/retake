defmodule Retake.Pipeline.Assemble do
  @moduledoc """
  Step 4 of the pipeline: the outputs of the script, stock and voice steps become one
  video spec (`spec/SPEC.md`). A pure function: no provider, no file, no clock.

  Input:

      %{
        id: "v-1a2b3c",                                  # the video's id (a spec id)
        brief: %{prompt: .., target_duration_ms: .., language: .., tone: .., audience: ..},
        script: %{title: .., scenes: [%{narration, visual_query, image_prompt, on_screen_text}]},
        scenes: [%{visual: %{asset: ..}, voice: %{asset: .., voiceover: .., duration_ms: ..}}]
      }

  with one entry in `scenes` for each scene of the script, in order, shaped as
  `Retake.Pipeline.Visuals.find/3` and `Retake.Pipeline.Voice.generate/3` return them.

  What the assembly decides:

    * ids: scenes `s1, s2, ...`, visuals `vis-1, ...`, voice-overs `vo-1, ...`;
    * each scene lasts as long as its voice-over (from the voice step);
    * a still image gets a slow zoom or pan (four patterns, in turn); a video plays from its
      start; both `cover` the frame;
    * the on-screen text, if any, is an overlay at the top for the first 2.5 s;
    * scenes join with cuts; captions are on (word highlight); no music yet (F05b).

  The spec is checked with `Retake.Spec.validate/1` before it is returned: a failure here
  is a bug in the pipeline, and is reported as one.
  """

  alias Retake.Spec

  @max_title 200
  @overlay_ms 2_500
  @target_slack 0.25

  # {from, to} of the slow camera move on a still image; one per scene in turn.
  @motions [
    {%{"scale" => 1.0, "x" => 0.0, "y" => 0.0}, %{"scale" => 1.12, "x" => 0.0, "y" => 0.0}},
    {%{"scale" => 1.12, "x" => -0.6, "y" => 0.0}, %{"scale" => 1.12, "x" => 0.6, "y" => 0.0}},
    {%{"scale" => 1.15, "x" => 0.0, "y" => 0.3}, %{"scale" => 1.0, "x" => 0.0, "y" => 0.0}},
    {%{"scale" => 1.1, "x" => 0.0, "y" => -0.5}, %{"scale" => 1.1, "x" => 0.0, "y" => 0.5}}
  ]

  @captions %{
    "enabled" => true,
    "style" => %{
      "mode" => "word_highlight",
      "max_words_per_line" => 3,
      "max_lines" => 2,
      "position" => "center",
      "highlight_color" => "#FFD400",
      "text" => %{
        "font_family" => "Inter",
        "font_weight" => 800,
        "font_size_px" => 76,
        "color" => "#FFFFFF",
        "stroke_color" => "#000000",
        "stroke_px" => 8,
        "uppercase" => true
      }
    }
  }

  @type input :: %{id: String.t(), brief: map(), script: map(), scenes: [map()]}

  @spec build(input()) ::
          {:ok, map(), [String.t()]}
          | {:error, {:spec_invalid, [Spec.error()]} | {:invalid_input, String.t()}}
  def build(%{id: id, brief: brief, script: script, scenes: parts}) do
    if length(script.scenes) == length(parts) do
      spec = spec(id, brief, script, parts)

      case Spec.validate(spec) do
        {:ok, spec} -> {:ok, spec, warnings(spec)}
        {:error, errors} -> {:error, {:spec_invalid, errors}}
      end
    else
      {:error,
       {:invalid_input,
        "the script has #{length(script.scenes)} scenes but #{length(parts)} were prepared"}}
    end
  end

  # --- the spec ----------------------------------------------------------------------------

  defp spec(id, brief, script, parts) do
    numbered = script.scenes |> Enum.zip(parts) |> Enum.with_index(1)

    %{
      "spec_version" => "0.2",
      "id" => id,
      "title" => script.title |> String.trim() |> String.slice(0, @max_title),
      "brief" => brief(brief),
      "output" => %{"width" => 1080, "height" => 1920, "fps" => 30, "background" => "#000000"},
      "assets" => assets(numbered),
      "scenes" => Enum.map(numbered, &scene/1),
      "captions" => @captions,
      "music" => nil,
      "loudness" => %{"integrated_lufs" => -14, "true_peak_dbtp" => -1}
    }
  end

  defp brief(brief) do
    %{
      "prompt" => brief.prompt,
      "target_duration_ms" => Map.get(brief, :target_duration_ms, 45_000),
      "language" => Map.get(brief, :language, "en")
    }
    |> put_present("tone", Map.get(brief, :tone))
    |> put_present("audience", Map.get(brief, :audience))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp assets(numbered) do
    Enum.reduce(numbered, %{}, fn {{_scene, part}, n}, assets ->
      assets
      |> Map.put("vis-#{n}", part.visual.asset)
      |> Map.put("vo-#{n}", part.voice.asset)
    end)
  end

  defp scene({{script_scene, part}, n}) do
    duration = part.voice.duration_ms

    %{
      "id" => "s#{n}",
      "intent" => intent(script_scene),
      "duration_ms" => duration,
      "visual" => visual("vis-#{n}", part.visual.asset, n),
      "voiceover" => Map.put(part.voice.voiceover, "asset", "vo-#{n}"),
      "transition_in" => if(n == 1, do: nil, else: %{"kind" => "cut", "duration_ms" => 0})
    }
    |> put_overlays(script_scene.on_screen_text, duration)
  end

  defp intent(script_scene) do
    %{"narration" => script_scene.narration, "visual_query" => script_scene.visual_query}
    |> put_present("image_prompt", Map.get(script_scene, :image_prompt))
    |> put_present("on_screen_text", script_scene.on_screen_text)
  end

  defp visual(asset_id, %{"kind" => "video"}, _n) do
    %{"asset" => asset_id, "fit" => "cover", "trim_start_ms" => 0}
  end

  defp visual(asset_id, image, n) do
    motions = motions(image)
    {from, to} = Enum.at(motions, rem(n - 1, length(motions)))

    %{
      "asset" => asset_id,
      "fit" => "cover",
      "motion" => %{"from" => from, "to" => to, "easing" => "ease_in_out"}
    }
  end

  # The sideways pan was chosen for tall stock photos. On a generated picture it can sweep across
  # the whole width and cut the subject at the edges, so a generated image only zooms or drifts
  # up and down.
  defp motions(%{"provenance" => %{"source" => "generated"}}), do: List.delete_at(@motions, 1)
  defp motions(_asset), do: @motions

  defp put_overlays(scene, nil, _duration), do: scene
  defp put_overlays(scene, "", _duration), do: scene

  defp put_overlays(scene, text, duration) do
    overlay = %{
      "text" => text,
      "start_ms" => 0,
      "end_ms" => min(@overlay_ms, duration),
      "position" => "top"
    }

    Map.put(scene, "overlays", [overlay])
  end

  # --- soft checks ---------------------------------------------------------------------------

  # SPEC.md: the total should be within 25% of the brief's target; a warning, not an error.
  defp warnings(spec) do
    total = spec["scenes"] |> Enum.map(& &1["duration_ms"]) |> Enum.sum()
    target = spec["brief"]["target_duration_ms"]

    if total < target * (1 - @target_slack) or total > target * (1 + @target_slack) do
      [
        "the video runs #{Float.round(total / 1000, 1)} s; the brief asked for about #{Float.round(target / 1000, 1)} s"
      ]
    else
      []
    end
  end
end
