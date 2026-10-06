defmodule Mix.Tasks.Retake.Video do
  @shortdoc "Makes a video from a topic: script, footage, narration, render"

  @moduledoc """
  The whole pipeline, for real: a topic goes in, a finished MP4 comes out.

      mix retake.video "why tea is good for you"
      mix retake.video --seconds 30 --tone playful --language en "how a battery works"

  Each step is announced as it happens (the script, then for every scene the footage and
  the narration, then the render). It needs everything the single steps need:
  `config/providers.toml`, `GROQ_API_KEY` for the script and the transcription, a stock key
  (`PIXABAY_API_KEY`), the Kokoro server (`just kokoro`) and the release build of the
  renderer (`just video` builds it). If your profile has an `image` slot and its keys are set
  (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`), scenes that have an image prompt get a
  generated image; the others, and any scene whose image fails, use stock footage.

  Options:

    * `--seconds N`       target length in seconds (default 45)
    * `--language CODE`, `--tone TEXT`, `--audience TEXT`
    * `--profile NAME`, `--config PATH` as for `mix help retake.script`
    * `--output PATH`     where to write the MP4 (default `.retake/out/<video id>.mp4`)
    * `--concurrency N`   scenes prepared at once (default 3)
    * `--json`            print the result as JSON when done

  Everything fetched or generated is cached, so repeating a topic is fast and free. The spec
  that was rendered is written next to the video, as `<id>.spec.json`.
  """

  use Mix.Task

  alias Retake.CLI
  alias Retake.Pipeline
  alias Retake.Providers.Client

  @switches [
    seconds: :integer,
    language: :string,
    tone: :string,
    audience: :string,
    profile: :string,
    config: :string,
    output: :string,
    concurrency: :integer,
    json: :boolean
  ]

  # Wait up to this long, in total, for a free service's rate limit to clear.
  @max_wait_ms 120_000

  @impl Mix.Task
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or words == [] do
      Mix.raise(~s|usage: mix retake.video [options] "your topic"   (see mix help retake.video)|)
    end

    Mix.Task.run("app.config")
    CLI.start_services()

    path = opts[:config] || CLI.default_config_path()
    id = Pipeline.new_video_id()

    case Client.from_file(path,
           profile: opts[:profile],
           video_id: id,
           max_wait_ms: @max_wait_ms,
           sleep: &wait/1
         ) do
      {:ok, client} -> make(client, id, path, Enum.join(words, " "), opts)
      {:error, reason} -> Mix.raise(CLI.describe(reason, path))
    end
  end

  # A free service's rate limit is making a call wait: say so, so it does not look hung.
  defp wait(ms) do
    Mix.shell().info(
      "              (rate limit: waiting #{Float.round(ms / 1000, 0) |> trunc()} s)"
    )

    Process.sleep(ms)
  end

  defp make(client, id, config_path, topic, opts) do
    out_dir = Path.join(CLI.project_root(config_path), ".retake/out")
    output = opts[:output] || Path.join(out_dir, "#{id}.mp4")
    started = System.monotonic_time(:second)

    Mix.shell().info(
      "making a video about #{inspect(topic)} (#{id}), profile #{client.profile}\n"
    )

    pipeline_opts =
      [video_id: id, output: output, on_event: printer()] ++
        if(opts[:concurrency], do: [concurrency: opts[:concurrency]], else: [])

    case Pipeline.run(client, brief(topic, opts), pipeline_opts) do
      {:ok, result} -> finish(result, started, opts[:json])
      {:error, failure} -> Mix.raise(failure_message(failure))
    end
  end

  defp brief(topic, opts) do
    %{
      prompt: topic,
      language: opts[:language],
      tone: opts[:tone],
      audience: opts[:audience],
      target_duration_ms: opts[:seconds] && opts[:seconds] * 1000
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # --- progress ------------------------------------------------------------------------------

  # Prints one line per event, and render progress in 10% steps. Events come from several
  # processes; the counter that remembers the last percentage printed is shared.
  defp printer do
    last_percent = :atomics.new(1, [])
    shell = Mix.shell()

    fn event -> line(event, last_percent) |> print(shell) end
  end

  defp print(nil, _shell), do: :ok
  defp print(text, shell), do: shell.info(text)

  defp line(%{step: :brief}, _last), do: nil
  defp line(%{step: :script, status: :started}, _last), do: "[script]      writing the script..."

  defp line(%{step: :script, status: :done} = e, _last),
    do: "[script]      #{e.scenes} scenes: #{inspect(e.title)}"

  defp line(%{step: :visual, scene: n, status: :done, source: :generated} = e, _last),
    do: "[scene #{n}] visual:  generated #{e.kind} for #{inspect(e.prompt)}"

  defp line(%{step: :visual, scene: n, status: :done} = e, _last),
    do: "[scene #{n}] visual:  #{e.kind} for #{inspect(e.query)} (#{e.credit})"

  defp line(%{step: :voice, scene: n, status: :done} = e, _last),
    do: "[scene #{n}] voice:   #{Float.round(e.duration_ms / 1000, 1)} s scene"

  defp line(%{step: :assemble, status: :done}, _last), do: "[assemble]    spec built and checked"
  defp line(%{step: :render, status: :started}, _last), do: "[render]      rendering..."

  defp line(%{step: :render, status: :progress, done: done, total: total}, last) do
    percent = div(done * 10, max(total, 1)) * 10

    if percent > :atomics.get(last, 1) do
      :atomics.put(last, 1, percent)
      "[render]      #{percent}%"
    end
  end

  defp line(%{status: :failed, step: step, scene: scene}, _last) do
    where = if scene, do: "scene #{scene} #{step}", else: "#{step}"
    "[failed]      #{where}"
  end

  defp line(_event, _last), do: nil

  # --- the end ------------------------------------------------------------------------------------

  defp finish(result, started, true) do
    seconds = System.monotonic_time(:second) - started

    json = %{
      "id" => result.id,
      "video" => result.output,
      "seconds_taken" => seconds,
      "warnings" => result.warnings,
      "title" => result.spec["title"]
    }

    Mix.shell().info(Jason.encode!(json, pretty: true))
  end

  defp finish(result, started, _json) do
    shell = Mix.shell()
    seconds = System.monotonic_time(:second) - started
    spec_path = Path.rootname(result.output) <> ".spec.json"
    File.write!(spec_path, Jason.encode!(result.spec, pretty: true))

    total_ms = result.spec["scenes"] |> Enum.map(& &1["duration_ms"]) |> Enum.sum()

    shell.info(
      "\ndone in #{seconds} s: #{inspect(result.spec["title"])}, #{Float.round(total_ms / 1000, 1)} s, #{length(result.spec["scenes"])} scenes"
    )

    shell.info("video:        #{result.output}")
    if windows = CLI.windows_path(result.output), do: shell.info("from Windows:  #{windows}")
    shell.info("spec:         #{spec_path}")

    shell.info("\ncredits:")

    for {_id, asset} <- Enum.sort(result.spec["assets"]), asset["license"] do
      shell.info("  #{asset["license"]["attribution"]}  (#{asset["license"]["name"]})")
    end

    for warning <- result.warnings, do: shell.info("\nwarning: #{warning}")
  end

  defp failure_message(%{step: step, scene: scene, reason: reason}) do
    where = if scene, do: "step #{step} of scene #{scene}", else: "step #{step}"
    "the video failed at #{where}:\n" <> CLI.describe(reason, nil)
  end
end
