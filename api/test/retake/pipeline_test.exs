defmodule Retake.PipelineTest do
  @moduledoc """
  The whole pipeline, offline, with the real renderer: a scripted stand-in for every provider
  (`Retake.Test.ScriptedAdapter`) returns a canned script, finds and "downloads" the fixture
  media, speaks silence and transcribes it. The MP4 that comes out is checked with ffprobe.

  Needs `ffprobe` on PATH and the debug renderer (`cargo build -p retake_render`).
  """

  # Renders video: run alone so it does not fight the other tests for the CPU.
  use ExUnit.Case, async: false

  alias Retake.Pipeline
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Spec
  alias Retake.Storage.Local

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @brief %{prompt: "Why tea is good for you", target_duration_ms: 8_000}

  defp toml(dir, overrides \\ %{}) do
    log = Path.join(dir, "calls.log")
    opt = fn name, extra -> Map.get(overrides, name, "") <> extra end

    """
    [retake]
    default_profile = "test"

    [profiles.test]
    llm = { use = "llm", fallbacks = [] }
    tts = { use = "voice", fallbacks = [] }
    stt = { use = "ears", fallbacks = [] }
    stock = { use = "stock", fallbacks = [] }
    music = { use = "llm", fallbacks = [] }

    [providers.llm]
    capability = "any"
    adapter = "scripted"
    role = "llm"
    log = "#{log}"
    #{opt.("llm", "")}

    [providers.voice]
    capability = "tts"
    adapter = "scripted"
    role = "tts"
    log = "#{log}"
    #{opt.("voice", "")}

    [providers.ears]
    capability = "stt"
    adapter = "scripted"
    role = "stt"
    log = "#{log}"
    #{opt.("ears", "")}

    [providers.stock]
    capability = "stock"
    adapter = "scripted"
    role = "stock"
    log = "#{log}"
    #{opt.("stock", "")}
    """
  end

  defp client(dir, overrides \\ %{}) do
    {:ok, config} = Config.parse(toml(dir, overrides))

    Client.new(
      config: config,
      profile: "test",
      storage: Local.new(Path.join(dir, "store")),
      cache_root: Path.join(dir, "cache"),
      usage: start_supervised!(Usage, id: make_ref())
    )
  end

  # Runs the pipeline, sending every event to the test process.
  defp run(client, dir, opts \\ []) do
    test = self()

    opts =
      Keyword.merge(
        [
          output: Path.join(dir, "out.mp4"),
          on_event: fn event -> send(test, {:event, event}) end
        ],
        opts
      )

    Pipeline.run(client, @brief, opts)
  end

  defp events(acc \\ []) do
    receive do
      {:event, event} -> events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls.log")) do
      {:ok, text} -> text |> String.split("\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp probe(path, streams) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-show_entries",
        "stream=codec_type,codec_name,width,height,sample_rate,channels:format=duration",
        "-of",
        "json",
        path
      ])

    decoded = Jason.decode!(out)

    {Enum.filter(decoded["streams"], &(&1["codec_type"] == streams)),
     decoded["format"]["duration"] |> String.to_float()}
  end

  # --- success ------------------------------------------------------------------------------------

  describe "run/3: a brief in, an MP4 out" do
    test "renders a 1080x1920 H.264 video with AAC narration as long as the spec says", %{
      tmp_dir: dir
    } do
      assert {:ok, %{id: id, spec: spec, output: output, warnings: warnings}} =
               run(client(dir), dir)

      assert "v-" <> _ = id
      assert output == Path.join(dir, "out.mp4")
      assert File.stat!(output).size > 0

      {[video], duration} = probe(output, "video")
      assert %{"codec_name" => "h264", "width" => 1080, "height" => 1920} = video

      {[audio], _} = probe(output, "audio")
      assert %{"codec_name" => "aac", "sample_rate" => "48000", "channels" => 2} = audio

      # each narration is 5 words at 400 ms = 2 s, plus 300 ms before and 500 ms after: three 2.8 s scenes
      expected = Enum.sum(Enum.map(spec["scenes"], & &1["duration_ms"])) / 1000
      assert_in_delta duration, expected, 0.15
      assert_in_delta expected, 8.4, 0.001

      assert Enum.any?(warnings, &(&1 =~ "captions"))
    end

    test "the spec is valid and uses video for the first scene and photos for the others", %{
      tmp_dir: dir
    } do
      {:ok, %{spec: spec}} = run(client(dir), dir)

      assert {:ok, _} = Spec.validate(spec)
      assert spec["title"] == "Tea in three scenes"
      assert spec["brief"]["prompt"] == "Why tea is good for you"

      kinds = Enum.map(spec["scenes"], &spec["assets"][&1["visual"]["asset"]]["kind"])
      assert kinds == ["video", "image", "image"]

      assert Enum.map(spec["scenes"], & &1["intent"]["visual_query"]) ==
               ["clip video steam", "photo gradient leaves", "photo sea sunrise"]

      assert hd(spec["scenes"])["overlays"] |> hd() |> Map.get("text") == "Wake Up"
    end

    test "every asset carries its provenance and licence", %{tmp_dir: dir} do
      {:ok, %{spec: spec}} = run(client(dir), dir)

      for {id, asset} <- spec["assets"] do
        assert %{"source" => source, "provider" => _, "request_hash" => "sha256:" <> _} =
                 asset["provenance"],
               id

        assert source in ["stock", "generated"]
      end

      assert spec["assets"]["vis-1"]["license"]["attribution"] ==
               "Video by Test Creator on Scripted"
    end

    test "narrates and times every scene", %{tmp_dir: dir} do
      {:ok, %{spec: spec}} = run(client(dir), dir)

      assert Enum.map(spec["scenes"], &length(&1["voiceover"]["words"])) == [5, 5, 5]
      assert Enum.all?(spec["scenes"], &(&1["voiceover"]["offset_ms"] == 300))
    end

    test "works with one scene at a time too", %{tmp_dir: dir} do
      assert {:ok, %{spec: spec}} = run(client(dir), dir, concurrency: 1)
      assert length(spec["scenes"]) == 3
    end

    test "needs no event callback", %{tmp_dir: dir} do
      assert {:ok, _} = Pipeline.run(client(dir), @brief, output: Path.join(dir, "quiet.mp4"))
    end

    test "a repeat is answered from the cache: no provider is called again", %{tmp_dir: dir} do
      client = client(dir)
      {:ok, _} = run(client, dir, output: Path.join(dir, "first.mp4"))
      first_calls = calls(dir)
      assert length(first_calls) > 0

      assert {:ok, %{output: output}} = run(client, dir, output: Path.join(dir, "second.mp4"))
      assert calls(dir) == first_calls
      assert File.stat!(output).size > 0
    end
  end

  describe "run/3: events" do
    test "announce each step, each scene's steps, and the render", %{tmp_dir: dir} do
      {:ok, _} = run(client(dir), dir)
      events = events()

      assert %{status: :done, scenes: 3, title: "Tea in three scenes"} =
               find(events, :script, nil, :done)

      for scene <- 1..3 do
        assert find(events, :stock, scene, :started)
        assert find(events, :stock, scene, :done)
        assert find(events, :voice, scene, :started)
        assert %{duration_ms: duration} = find(events, :voice, scene, :done)
        assert duration > 0
      end

      assert %{kind: "video", credit: "Video by Test Creator on Scripted"} =
               find(events, :stock, 1, :done)

      assert %{kind: "image"} = find(events, :stock, 2, :done)

      assert find(events, :assemble, nil, :done)
      assert find(events, :render, nil, :started)
      assert %{done: done, total: total} = last_progress(events)
      assert done == total
      assert find(events, :render, nil, :done)
    end

    test "arrive in pipeline order: script, then the scenes, then assemble, then render", %{
      tmp_dir: dir
    } do
      {:ok, _} = run(client(dir), dir)
      steps = Enum.map(events(), & &1.step)

      assert hd(steps) == :brief
      assert Enum.find(steps, &(&1 != :brief)) == :script

      last_script =
        steps
        |> Enum.with_index()
        |> Enum.filter(&(elem(&1, 0) == :script))
        |> List.last()
        |> elem(1)

      first_scene = Enum.find_index(steps, &(&1 in [:stock, :voice]))

      last_scene =
        steps
        |> Enum.with_index()
        |> Enum.filter(&(elem(&1, 0) in [:stock, :voice]))
        |> List.last()
        |> elem(1)

      first_assemble = Enum.find_index(steps, &(&1 == :assemble))
      first_render = Enum.find_index(steps, &(&1 == :render))

      assert first_scene > last_script
      assert first_assemble > last_scene
      assert first_render > first_assemble
      assert List.last(steps) == :render
    end
  end

  describe "run/3: failures name the step and the scene" do
    test "a script failure stops everything", %{tmp_dir: dir} do
      client = client(dir, %{"llm" => "fail = true"})

      assert {:error,
              %{step: :script, scene: nil, reason: {:all_providers_failed, [%{provider: "llm"}]}}} =
               run(client, dir)

      events = events()
      assert find(events, :script, nil, :failed)
      refute Enum.any?(events, &(&1.step in [:stock, :voice, :assemble, :render]))
      refute File.exists?(Path.join(dir, "out.mp4"))
    end

    test "footage not found for a scene fails that scene's stock step", %{tmp_dir: dir} do
      client = client(dir, %{"stock" => ~s(empty_for = "sea")})

      assert {:error, %{step: :stock, scene: 3, reason: {:no_stock_found, queries}}} =
               run(client, dir)

      assert "photo sea sunrise" in queries

      events = events()
      assert find(events, :stock, 3, :failed)
      refute Enum.any?(events, &(&1.step in [:assemble, :render]))
      refute File.exists?(Path.join(dir, "out.mp4"))
    end

    test "a voice failure names the voice step", %{tmp_dir: dir} do
      client = client(dir, %{"voice" => "fail = true"})

      assert {:error,
              %{
                step: :voice,
                scene: scene,
                reason: {:all_providers_failed, [%{provider: "voice"}]}
              }} =
               run(client, dir)

      assert scene in 1..3
      refute File.exists?(Path.join(dir, "out.mp4"))
    end

    test "a transcription failure names the voice step", %{tmp_dir: dir} do
      client = client(dir, %{"ears" => "fail = true"})

      assert {:error, %{step: :voice, reason: {:all_providers_failed, [%{provider: "ears"}]}}} =
               run(client, dir)
    end

    test "a renderer that is missing fails the render step, after everything else worked", %{
      tmp_dir: dir
    } do
      assert {:error, %{step: :render, scene: nil, reason: %{kind: :renderer_not_found}}} =
               run(client(dir), dir, renderer: Path.join(dir, "no-such-renderer"))

      events = events()
      assert find(events, :assemble, nil, :done)
      assert find(events, :render, nil, :failed)
    end

    test "an invalid brief is refused before any provider is called", %{tmp_dir: dir} do
      assert {:error, %{step: :brief, scene: nil, reason: {:invalid_brief, [message]}}} =
               Pipeline.run(client(dir), %{prompt: "  "}, output: Path.join(dir, "out.mp4"))

      assert message =~ "prompt"
      assert calls(dir) == []
    end
  end

  test "new_video_id/0 is a valid spec id and different each time" do
    ids = for _ <- 1..20, do: Pipeline.new_video_id()

    assert length(Enum.uniq(ids)) == 20
    assert Enum.all?(ids, &Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, &1))
  end

  # --- helpers over the event list ---------------------------------------------------------------------

  defp find(events, step, scene, status) do
    Enum.find(events, &(&1.step == step and &1.scene == scene and &1.status == status))
  end

  defp last_progress(events) do
    events |> Enum.filter(&(&1.status == :progress)) |> List.last()
  end
end
