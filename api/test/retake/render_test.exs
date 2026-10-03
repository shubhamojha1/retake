defmodule Retake.RenderTest do
  use ExUnit.Case, async: true

  alias Retake.Render
  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @root Path.expand("../../..", __DIR__)

  defp fixture(name) do
    @root |> Path.join("fixtures/specs/#{name}") |> File.read!() |> Jason.decode!()
  end

  # minimal.json cut to one second (30 frames) so the real renderer finishes quickly.
  defp short_minimal do
    put_in(fixture("minimal.json"), ["scenes", Access.at(0), "duration_ms"], 1000)
  end

  # A stand-in renderer: a shell script that speaks (or breaks) the line protocol.
  defp script(dir, body) do
    path = Path.join(dir, "fake-renderer.sh")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  defp progress_to_self do
    test = self()
    fn done, total -> send(test, {:progress, done, total}) end
  end

  test "the test config points at the debug renderer build" do
    assert Render.renderer_bin() == Path.join(@root, "target/debug/retake_render")
  end

  describe "with the real renderer" do
    test "writes an MP4 and reports the renderer's warnings", %{tmp_dir: dir} do
      output = Path.join(dir, "out.mp4")

      assert {:ok, %{path: ^output, warnings: warnings}} =
               Render.run(short_minimal(), output: output, base_dir: @root)

      assert <<_size::32, "ftyp", _rest::binary>> = File.read!(output)
      assert Enum.any?(warnings, &(&1 =~ "captions"))
    end

    test "reports progress as the renderer works", %{tmp_dir: dir} do
      output = Path.join(dir, "out.mp4")
      opts = [output: output, base_dir: @root, on_progress: progress_to_self()]

      assert {:ok, _} = Render.run(short_minimal(), opts)
      assert_received {:progress, 10, 30}
      assert_received {:progress, 20, 30}
      assert_received {:progress, 30, 30}
    end

    test "resolves store:// uris through the storage", %{tmp_dir: dir} do
      storage = Local.new(Path.join(dir, "store"))

      spec =
        for {id, asset} <- short_minimal()["assets"], reduce: short_minimal() do
          acc ->
            file = Path.join(@root, String.replace_prefix(asset["uri"], "file://", ""))

            {:ok, ref} =
              Storage.put(
                storage,
                File.read!(file),
                file |> Path.extname() |> String.trim_leading(".")
              )

            put_in(acc, ["assets", id, "uri"], ref.uri)
        end

      output = Path.join(dir, "out.mp4")
      # base_dir is somewhere without the fixtures: only the storage can supply the files
      assert {:ok, %{path: ^output}} =
               Render.run(spec, output: output, storage: storage, base_dir: dir)

      assert File.stat!(output).size > 0
    end

    test "a missing asset file is a structured error and writes nothing", %{tmp_dir: dir} do
      output = Path.join(dir, "out.mp4")

      spec =
        put_in(short_minimal(), ["assets", "img-sea", "uri"], "file://fixtures/media/nope.jpg")

      assert {:error, %{kind: :render_failed, message: message, warnings: warnings}} =
               Render.run(spec, output: output, base_dir: @root)

      assert message =~ "nope.jpg"
      assert is_list(warnings)
      refute File.exists?(output)
    end

    test "an invalid spec is a structured error", %{tmp_dir: dir} do
      spec = put_in(short_minimal(), ["spec_version"], "0.2")

      assert {:error, %{kind: :render_failed, message: message}} =
               Render.run(spec, output: Path.join(dir, "out.mp4"), base_dir: @root)

      assert message =~ "spec_version"
    end
  end

  describe "before the renderer starts" do
    test "a missing renderer binary says how to build it", %{tmp_dir: dir} do
      assert {:error, %{kind: :renderer_not_found, message: message}} =
               Render.run(short_minimal(),
                 output: Path.join(dir, "out.mp4"),
                 renderer: Path.join(dir, "nope")
               )

      assert message =~ "nope"
      assert message =~ "cargo build"
    end

    test "a store:// uri that is not in the storage", %{tmp_dir: dir} do
      storage = Local.new(Path.join(dir, "store"))
      uri = "store://assets/#{String.duplicate("0", 64)}.jpg"
      spec = put_in(short_minimal(), ["assets", "img-sea", "uri"], uri)

      assert {:error, %{kind: :asset_not_found, message: message}} =
               Render.run(spec, output: Path.join(dir, "out.mp4"), storage: storage)

      assert message =~ "img-sea"
      refute File.exists?(Path.join(dir, "out.mp4"))
    end

    test "a store:// uri with no storage given", %{tmp_dir: dir} do
      uri = "store://assets/#{String.duplicate("0", 64)}.jpg"
      spec = put_in(short_minimal(), ["assets", "img-sea", "uri"], uri)

      assert {:error, %{kind: :asset_not_found, message: message}} =
               Render.run(spec, output: Path.join(dir, "out.mp4"))

      assert message =~ "storage"
    end
  end

  describe "the line protocol (stand-in renderer)" do
    test "collects warnings, forwards progress, returns the done path", %{tmp_dir: dir} do
      bin =
        script(dir, """
        echo "warning: first"
        echo "progress 1/2"
        echo "progress 2/2"
        echo "warning: second"
        echo "done /tmp/x.mp4"
        """)

      assert Render.run(%{}, output: "/tmp/x.mp4", renderer: bin, on_progress: progress_to_self()) ==
               {:ok, %{path: "/tmp/x.mp4", warnings: ["first", "second"]}}

      assert_received {:progress, 1, 2}
      assert_received {:progress, 2, 2}
    end

    test "is called with the spec file and -o <output>; the spec file is removed afterwards", %{
      tmp_dir: dir
    } do
      bin =
        script(dir, """
        echo "$@" > "#{dir}/args.txt"
        cp "$1" "#{dir}/seen.json"
        echo "done $3"
        """)

      output = Path.join(dir, "out.mp4")
      storage = Local.new(Path.join(dir, "store"))
      {:ok, ref} = Storage.put(storage, "pixels", "jpg")

      spec = %{
        "assets" => %{"a" => %{"uri" => ref.uri}, "b" => %{"uri" => "file://fixtures/b.jpg"}}
      }

      assert {:ok, %{path: ^output}} =
               Render.run(spec, output: output, renderer: bin, storage: storage)

      [spec_path, "-o", ^output] = dir |> Path.join("args.txt") |> File.read!() |> String.split()
      assert Path.extname(spec_path) == ".json"
      refute File.exists?(spec_path)

      seen = dir |> Path.join("seen.json") |> File.read!() |> Jason.decode!()
      assert "file://" <> stored = seen["assets"]["a"]["uri"]
      assert File.read!(stored) == "pixels"
      assert seen["assets"]["b"]["uri"] == "file://fixtures/b.jpg"
    end

    test "runs the renderer in base_dir", %{tmp_dir: dir} do
      bin = script(dir, ~s|echo "done $(pwd)"|)
      assert {:ok, %{path: path}} = Render.run(%{}, output: "x.mp4", renderer: bin, base_dir: dir)
      assert Path.expand(path) == Path.expand(dir)
    end

    test "an error line becomes the error message", %{tmp_dir: dir} do
      bin = script(dir, ~s|echo "error: boom"\nexit 1|)

      assert {:error, %{kind: :render_failed, message: "boom"}} =
               Render.run(%{}, output: "x.mp4", renderer: bin)
    end

    test "warnings seen before a failure are returned with it", %{tmp_dir: dir} do
      bin = script(dir, ~s|echo "warning: w"\necho "error: bad"\nexit 1|)

      assert {:error, %{kind: :render_failed, warnings: ["w"]}} =
               Render.run(%{}, output: "x.mp4", renderer: bin)
    end

    test "other output (FFmpeg's own messages) is kept to explain a failure", %{tmp_dir: dir} do
      bin = script(dir, ~s|echo "some ffmpeg complaint"\nexit 2|)

      assert {:error, %{kind: :render_failed, message: message}} =
               Render.run(%{}, output: "x.mp4", renderer: bin)

      assert message =~ "some ffmpeg complaint"
    end

    test "a clean exit without a done line is a failure", %{tmp_dir: dir} do
      bin = script(dir, ~s|echo "progress 1/1"|)

      assert {:error, %{kind: :render_failed, message: message}} =
               Render.run(%{}, output: "x.mp4", renderer: bin)

      assert message =~ "without"
    end

    test "a line longer than the port's buffer does not break parsing", %{tmp_dir: dir} do
      bin =
        script(dir, """
        head -c 10000 /dev/zero | tr '\\0' x
        echo
        echo "done /x.mp4"
        """)

      assert {:ok, %{path: "/x.mp4"}} = Render.run(%{}, output: "x.mp4", renderer: bin)
    end

    test "a renderer that hangs is killed after the timeout", %{tmp_dir: dir} do
      bin =
        script(dir, """
        echo "warning: slow start"
        echo $$ > "#{dir}/pid"
        sleep 30
        """)

      assert {:error, %{kind: :timeout, message: message, warnings: ["slow start"]}} =
               Render.run(%{}, output: "x.mp4", renderer: bin, timeout: 1_000)

      assert message =~ "1000"

      pid = dir |> Path.join("pid") |> File.read!() |> String.trim()

      assert eventually(fn -> not File.exists?("/proc/#{pid}") end),
             "process #{pid} is still running"
    end
  end

  # Polls briefly: a killed process takes a moment to disappear.
  defp eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          20 -> eventually(check, attempts - 1)
        end
    end
  end
end
