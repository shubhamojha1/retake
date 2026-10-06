defmodule Retake.Pipeline.AssembleTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Assemble
  alias Retake.Spec

  # --- building the pieces the earlier steps return ------------------------------------------

  defp hex(n), do: String.duplicate(Integer.to_string(rem(n, 10)), 64)

  defp provenance(n, capability) do
    %{
      "source" => if(capability == "tts", do: "generated", else: "stock"),
      "capability" => capability,
      "provider" => if(capability == "tts", do: "kokoro-local", else: "pixabay"),
      "model" => "",
      "request" => %{"n" => n},
      "request_hash" => "sha256:" <> hex(n + 5),
      "created_at" => "2026-10-04T12:00:00Z",
      "cost" => %{"amount" => 0.0, "currency" => "USD", "units" => %{}}
    }
  end

  defp stock_asset(n, "image") do
    %{
      "kind" => "image",
      "uri" => "store://assets/#{hex(n)}.jpg",
      "content_hash" => "sha256:" <> hex(n),
      "media" => %{"width" => 1350, "height" => 2400, "mime" => "image/jpeg"},
      "provenance" => provenance(n, "stock"),
      "license" => %{
        "name" => "Pixabay Content License",
        "source_url" => "https://pixabay.com/photos/x-#{n}/",
        "attribution" => "Photo by Jo on Pixabay"
      }
    }
  end

  defp stock_asset(n, "video") do
    %{
      "kind" => "video",
      "uri" => "store://assets/#{hex(n)}.mp4",
      "content_hash" => "sha256:" <> hex(n),
      "media" => %{
        "width" => 1080,
        "height" => 1920,
        "duration_ms" => 12_000,
        "mime" => "video/mp4"
      },
      "provenance" => provenance(n, "stock"),
      "license" => %{
        "name" => "Pixabay Content License",
        "source_url" => "https://pixabay.com/videos/x-#{n}/",
        "attribution" => "Video by Jo on Pixabay"
      }
    }
  end

  # 3 s of audio, voice starting 300 ms in, 500 ms of padding: a 3800 ms scene.
  defp voice(n, opts \\ []) do
    %{
      asset: %{
        "kind" => "audio",
        "uri" => "store://assets/#{hex(n + 3)}.wav",
        "content_hash" => "sha256:" <> hex(n + 3),
        "media" => %{
          "duration_ms" => 3000,
          "sample_rate" => 24_000,
          "channels" => 1,
          "mime" => "audio/wav"
        },
        "provenance" => provenance(n, "tts")
      },
      voiceover: %{
        "offset_ms" => 300,
        "words" =>
          Keyword.get(opts, :words, [
            %{"text" => "Hello", "start_ms" => 0, "end_ms" => 400},
            %{"text" => "world.", "start_ms" => 500, "end_ms" => 1200}
          ])
      },
      duration_ms: Keyword.get(opts, :duration_ms, 3800),
      warnings: []
    }
  end

  defp part(n, kind, opts \\ []) do
    %{
      visual: %{
        asset: stock_asset(n, kind),
        query: "query #{n}",
        source: :stock,
        prompt: nil,
        warnings: []
      },
      voice: voice(n, opts)
    }
  end

  defp script_scene(n, on_screen_text \\ nil) do
    %{
      narration: "Narration of scene #{n}.",
      visual_query: "visual query #{n}",
      on_screen_text: on_screen_text
    }
  end

  defp input(kinds \\ ["video", "image", "image"], overrides \\ %{}) do
    Map.merge(
      %{
        id: "v-abc123",
        brief: %{
          prompt: "Why tea is good for you",
          target_duration_ms: 12_000,
          language: "en",
          tone: "friendly",
          audience: "adults"
        },
        script: %{
          title: "Tea facts",
          scenes: for({_kind, n} <- Enum.with_index(kinds, 1), do: script_scene(n))
        },
        scenes: for({kind, n} <- Enum.with_index(kinds, 1), do: part(n, kind))
      },
      overrides
    )
  end

  defp build!(input) do
    assert {:ok, spec, warnings} = Assemble.build(input)
    {spec, warnings}
  end

  # --- the spec -------------------------------------------------------------------------------

  describe "build/1" do
    test "returns a spec that passes the validator" do
      {spec, _warnings} = build!(input())
      assert {:ok, ^spec} = Spec.validate(spec)
    end

    test "titles the video and carries the brief" do
      {spec, _} = build!(input())

      assert spec["spec_version"] == "0.2"
      assert spec["id"] == "v-abc123"
      assert spec["title"] == "Tea facts"

      assert spec["brief"] == %{
               "prompt" => "Why tea is good for you",
               "target_duration_ms" => 12_000,
               "language" => "en",
               "tone" => "friendly",
               "audience" => "adults"
             }
    end

    test "puts the script's image_prompt in the scene intent, and leaves it out when there is none" do
      scenes = [
        script_scene(1) |> Map.put(:image_prompt, "A dim room, vertical shot."),
        script_scene(2) |> Map.put(:image_prompt, nil),
        script_scene(3)
      ]

      input = input(["image", "image", "image"], %{script: %{title: "Tea facts", scenes: scenes}})
      {spec, _} = build!(input)

      assert Enum.at(spec["scenes"], 0)["intent"]["image_prompt"] == "A dim room, vertical shot."
      refute Map.has_key?(Enum.at(spec["scenes"], 1)["intent"], "image_prompt")
      refute Map.has_key?(Enum.at(spec["scenes"], 2)["intent"], "image_prompt")
      assert {:ok, _} = Spec.validate(spec)
    end

    test "a generated image zooms or drifts up and down but never pans sideways" do
      base = input(["image", "image", "image", "image"])

      scenes =
        Enum.map(base.scenes, fn part ->
          put_in(part, [:visual, :asset, "provenance", "source"], "generated")
        end)

      {spec, _} = build!(%{base | scenes: scenes})

      for scene <- spec["scenes"] do
        %{"from" => from, "to" => to} = scene["visual"]["motion"]
        assert from["x"] == to["x"], "scene #{scene["id"]} pans sideways"
      end
    end

    test "a stock image still gets the sideways pan in its turn" do
      {spec, _} = build!(input(["image", "image", "image", "image"]))

      assert Enum.any?(spec["scenes"], fn scene ->
               %{"from" => from, "to" => to} = scene["visual"]["motion"]
               from["x"] != to["x"]
             end)
    end

    test "leaves tone and audience out when there are none" do
      brief = %{
        prompt: "Tea",
        target_duration_ms: 12_000,
        language: "en",
        tone: nil,
        audience: ""
      }

      {spec, _} = build!(input(["image"], %{brief: brief}))

      assert spec["brief"] == %{
               "prompt" => "Tea",
               "target_duration_ms" => 12_000,
               "language" => "en"
             }
    end

    test "a missing target and language fall back to 45 s and English" do
      {spec, _} = build!(input(["image"], %{brief: %{prompt: "Tea"}}))
      assert %{"target_duration_ms" => 45_000, "language" => "en"} = spec["brief"]
    end

    test "is a 1080x1920 30 fps video with captions on, no music, and a loudness target" do
      {spec, _} = build!(input())

      assert spec["output"] == %{
               "width" => 1080,
               "height" => 1920,
               "fps" => 30,
               "background" => "#000000"
             }

      assert spec["captions"]["enabled"] == true
      assert spec["captions"]["style"]["mode"] == "word_highlight"
      assert spec["music"] == nil
      assert spec["loudness"] == %{"integrated_lufs" => -14, "true_peak_dbtp" => -1}
    end

    test "a title over 200 characters is cut" do
      {spec, _} =
        build!(
          input(["image"], %{
            script: %{title: String.duplicate("t", 250), scenes: [script_scene(1)]}
          })
        )

      assert String.length(spec["title"]) == 200
    end
  end

  describe "ids and assets" do
    test "scenes, visuals and voice-overs are numbered in order" do
      {spec, _} = build!(input())

      assert Enum.map(spec["scenes"], & &1["id"]) == ["s1", "s2", "s3"]
      assert Enum.map(spec["scenes"], & &1["visual"]["asset"]) == ["vis-1", "vis-2", "vis-3"]
      assert Enum.map(spec["scenes"], & &1["voiceover"]["asset"]) == ["vo-1", "vo-2", "vo-3"]

      assert spec["assets"] |> Map.keys() |> Enum.sort() == [
               "vis-1",
               "vis-2",
               "vis-3",
               "vo-1",
               "vo-2",
               "vo-3"
             ]
    end

    test "the assets are the ones the steps returned, licence and provenance included" do
      {spec, _} = build!(input())

      assert spec["assets"]["vis-1"] == stock_asset(1, "video")
      assert spec["assets"]["vis-2"] == stock_asset(2, "image")
      assert spec["assets"]["vo-1"]["provenance"]["capability"] == "tts"
      assert spec["assets"]["vis-1"]["license"]["attribution"] == "Video by Jo on Pixabay"
    end
  end

  describe "scenes" do
    test "the intent is the script's" do
      scenes = [script_scene(1, "Heart Health"), script_scene(2)]
      {spec, _} = build!(input(["image", "image"], %{script: %{title: "T", scenes: scenes}}))

      assert hd(spec["scenes"])["intent"] == %{
               "narration" => "Narration of scene 1.",
               "visual_query" => "visual query 1",
               "on_screen_text" => "Heart Health"
             }

      assert Enum.at(spec["scenes"], 1)["intent"] == %{
               "narration" => "Narration of scene 2.",
               "visual_query" => "visual query 2"
             }
    end

    test "each scene lasts as long as its voice-over step says" do
      parts = [part(1, "image"), %{part(2, "image") | voice: voice(2, duration_ms: 5200)}]
      script = %{title: "T", scenes: [script_scene(1), script_scene(2)]}
      {spec, _} = build!(input(["image", "image"], %{scenes: parts, script: script}))

      assert Enum.map(spec["scenes"], & &1["duration_ms"]) == [3800, 5200]
    end

    test "the voice-over carries its offset and timed words" do
      {spec, _} = build!(input())

      assert %{
               "asset" => "vo-1",
               "offset_ms" => 300,
               "words" => [%{"text" => "Hello"}, %{"text" => "world."}]
             } =
               hd(spec["scenes"])["voiceover"]
    end

    test "the first scene has no transition, the rest cut" do
      {spec, _} = build!(input())

      assert Enum.map(spec["scenes"], & &1["transition_in"]) ==
               [
                 nil,
                 %{"kind" => "cut", "duration_ms" => 0},
                 %{"kind" => "cut", "duration_ms" => 0}
               ]
    end

    test "on-screen text becomes a top overlay for the first 2.5 s, or the whole scene if shorter" do
      scenes = [script_scene(1, "Heart Health"), script_scene(2, "Short")]
      # the second scene is short: 1.2 s of audio, 300 ms before it and 500 ms after = 2 s
      short = put_in(voice(2, duration_ms: 2000), [:asset, "media", "duration_ms"], 1200)
      parts = [part(1, "image"), %{part(2, "image") | voice: short}]

      {spec, _} =
        build!(input(["image", "image"], %{script: %{title: "T", scenes: scenes}, scenes: parts}))

      assert hd(spec["scenes"])["overlays"] == [
               %{"text" => "Heart Health", "start_ms" => 0, "end_ms" => 2500, "position" => "top"}
             ]

      assert [%{"end_ms" => 2000}] = Enum.at(spec["scenes"], 1)["overlays"]
    end

    test "no on-screen text, no overlays" do
      {spec, _} = build!(input())
      refute Enum.any?(spec["scenes"], &Map.has_key?(&1, "overlays"))
    end
  end

  describe "visuals" do
    test "a video plays from its start and covers the frame, with no motion" do
      {spec, _} = build!(input())

      assert hd(spec["scenes"])["visual"] == %{
               "asset" => "vis-1",
               "fit" => "cover",
               "trim_start_ms" => 0
             }
    end

    test "a still image covers the frame with a slow camera move" do
      {spec, _} = build!(input())

      assert %{
               "asset" => "vis-2",
               "fit" => "cover",
               "motion" => %{"from" => from, "to" => to, "easing" => "ease_in_out"}
             } =
               Enum.at(spec["scenes"], 1)["visual"]

      assert from != to
    end

    test "the camera move changes from scene to scene, and every pattern is valid" do
      kinds = List.duplicate("image", 5)
      {spec, _} = build!(input(kinds, %{brief: %{prompt: "Tea", target_duration_ms: 19_000}}))

      motions = Enum.map(spec["scenes"], & &1["visual"]["motion"])
      assert length(Enum.uniq(Enum.take(motions, 4))) == 4
      assert Enum.at(motions, 4) == hd(motions)
      assert {:ok, _} = Spec.validate(spec)
    end
  end

  describe "warnings" do
    test "none when the video is near the target length" do
      # three 3.8 s scenes = 11.4 s against a 12 s target
      {_spec, warnings} = build!(input())
      assert warnings == []
    end

    test "a video far from the target length is flagged, not rejected" do
      brief = %{prompt: "Tea", target_duration_ms: 45_000, language: "en"}
      {_spec, [warning]} = build!(input(["video", "image", "image"], %{brief: brief}))

      assert warning =~ "11.4 s"
      assert warning =~ "45.0 s"
    end
  end

  describe "failures" do
    test "a different number of prepared scenes than script scenes" do
      assert {:error, {:invalid_input, message}} =
               Assemble.build(input(["image", "image"], %{scenes: [part(1, "image")]}))

      assert message =~ "2 scenes"
    end

    test "an invalid assembly is reported with the validator's errors" do
      words = [
        %{"text" => "a", "start_ms" => 0, "end_ms" => 500},
        %{"text" => "b", "start_ms" => 100, "end_ms" => 600}
      ]

      parts = [%{part(1, "image") | voice: voice(1, words: words)}]

      assert {:error, {:spec_invalid, errors}} =
               Assemble.build(input(["image"], %{scenes: parts}))

      assert Enum.any?(
               errors,
               &(&1.path == "/scenes/0/voiceover/words/1" and &1.rule == :words_out_of_order)
             )
    end

    test "a scene too short for its voice-over is caught" do
      parts = [%{part(1, "image") | voice: voice(1, duration_ms: 2000)}]

      assert {:error, {:spec_invalid, errors}} =
               Assemble.build(input(["image"], %{scenes: parts}))

      assert Enum.any?(errors, &(&1.rule == :voiceover_too_long))
    end

    test "a video id that is not a valid spec id is caught" do
      assert {:error, {:spec_invalid, errors}} =
               Assemble.build(input(["image"], %{id: "Not Valid!"}))

      assert Enum.any?(errors, &(&1.path == "/id"))
    end
  end
end
