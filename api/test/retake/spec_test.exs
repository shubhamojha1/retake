defmodule Retake.SpecTest do
  use ExUnit.Case, async: true

  alias Retake.Spec

  @examples Path.expand("../../../spec/examples", __DIR__)

  defp example_path(name), do: Path.join(@examples, name)
  defp example(name), do: name |> example_path() |> File.read!() |> Jason.decode!()

  defp set(spec, path, value), do: put_in(spec, path, value)

  # Asserts that some error has this JSON Pointer path and rule. Other errors may exist.
  defp assert_error({:error, errors}, path, rule) do
    assert Enum.any?(errors, &(&1.path == path and &1.rule == rule)),
           "expected #{inspect(rule)} at #{inspect(path)}, got: #{inspect(errors)}"
  end

  defp assert_error(other, path, rule),
    do: flunk("expected error #{inspect(rule)} at #{inspect(path)}, got: #{inspect(other)}")

  describe "example specs" do
    for name <- ["minimal.json", "explainer.json"] do
      test "#{name} is valid" do
        assert {:ok, %{"spec_version" => "0.1"}} = Spec.validate(example(unquote(name)))
      end
    end
  end

  describe "load/1" do
    test "loads and validates a spec file" do
      assert {:ok, %{"id" => "minimal-demo"}} = Spec.load(example_path("minimal.json"))
    end

    @tag :tmp_dir
    test "reports invalid JSON as an error", %{tmp_dir: dir} do
      path = Path.join(dir, "broken.json")
      File.write!(path, "{ not json")
      assert {:error, [%{path: "", rule: :json}]} = Spec.load(path)
    end

    test "reports a missing file as an error" do
      assert {:error, [%{path: "", rule: :file}]} = Spec.load(example_path("nope.json"))
    end
  end

  describe "shape (JSON Schema)" do
    test "wrong value points at its path" do
      result = "minimal.json" |> example() |> set(["output", "fps"], 60) |> Spec.validate()
      assert_error(result, "/output/fps", :schema)
    end

    test "missing required field points at the missing field" do
      result = "minimal.json" |> example() |> Map.delete("title") |> Spec.validate()
      assert_error(result, "/title", :schema)
    end

    test "unsupported spec_version is rejected" do
      result = "minimal.json" |> example() |> set(["spec_version"], "0.2") |> Spec.validate()
      assert_error(result, "/spec_version", :schema)
    end

    test "returns every error, not just the first" do
      result =
        "minimal.json"
        |> example()
        |> set(["output", "fps"], 60)
        |> set(["title"], "")
        |> Spec.validate()

      assert_error(result, "/output/fps", :schema)
      assert_error(result, "/title", :schema)
    end

    test "semantic rules are skipped when the shape is wrong" do
      # dangling asset id AND a missing title: only the shape error is reported
      result =
        "minimal.json"
        |> example()
        |> Map.delete("title")
        |> set(["scenes", Access.at(0), "visual", "asset"], "nope")
        |> Spec.validate()

      assert_error(result, "/title", :schema)
      assert {:error, errors} = result
      refute Enum.any?(errors, &(&1.rule == :asset_not_found))
    end
  end

  describe "rule: asset ids exist" do
    test "visual asset" do
      result =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "visual", "asset"], "nope")
        |> Spec.validate()

      assert_error(result, "/scenes/0/visual/asset", :asset_not_found)
    end

    test "voice-over asset" do
      result =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "voiceover", "asset"], "nope")
        |> Spec.validate()

      assert_error(result, "/scenes/0/voiceover/asset", :asset_not_found)
    end

    test "music asset" do
      result =
        "explainer.json" |> example() |> set(["music", "asset"], "nope") |> Spec.validate()

      assert_error(result, "/music/asset", :asset_not_found)
    end
  end

  describe "rule: voice-over fits its scene" do
    # minimal.json: voice-over 4200 ms at offset 300 ms, so 4500 ms is the minimum scene length

    test "scene one millisecond too short" do
      result =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "duration_ms"], 4499)
        |> Spec.validate()

      assert_error(result, "/scenes/0/voiceover", :voiceover_too_long)
    end

    test "scene exactly long enough is valid" do
      spec = "minimal.json" |> example() |> set(["scenes", Access.at(0), "duration_ms"], 4500)
      assert {:ok, _} = Spec.validate(spec)
    end
  end

  describe "rule: transition shorter than both neighbouring scenes" do
    test "transition as long as the previous scene" do
      result =
        "explainer.json"
        |> example()
        |> set(["scenes", Access.at(0), "duration_ms"], 2000)
        |> set(["scenes", Access.at(1), "transition_in", "duration_ms"], 2000)
        |> Spec.validate()

      assert_error(result, "/scenes/1/transition_in/duration_ms", :transition_too_long)
    end
  end

  describe "rule: words in order and inside the audio" do
    test "word starts before the previous word ends" do
      result =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "voiceover", "words", Access.at(1), "start_ms"], 100)
        |> Spec.validate()

      assert_error(result, "/scenes/0/voiceover/words/1", :words_out_of_order)
    end

    test "word ends after the audio ends" do
      # minimal.json voice-over is 4200 ms long
      result =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "voiceover", "words", Access.at(4), "end_ms"], 4201)
        |> Spec.validate()

      assert_error(result, "/scenes/0/voiceover/words/4", :word_past_audio_end)
    end
  end
end
