defmodule Retake.Pipeline do
  @moduledoc """
  The whole pipeline: a brief in, a finished video out.

      brief --script--> scenes --(stock + voice, per scene, in parallel)--> assemble --> render

    1. `Retake.Pipeline.Script`: the LLM writes the title and the scenes;
    2. for each scene, in parallel (up to `:concurrency` scenes at once, and the stock and the
       voice step of one scene side by side): `Retake.Pipeline.Stock` finds and downloads the
       footage, `Retake.Pipeline.Voice` makes the narration with its word timings;
    3. `Retake.Pipeline.Assemble` joins everything into a spec and validates it;
    4. `Retake.Render` renders the spec to an MP4 in a separate process.

  Steps talk to providers only through the `Retake.Providers.Client` you pass in, so the
  profile decides which services answer, and everything is cached.

  ## Events

  `:on_event` is called with a map for each thing that happens, from whichever process it
  happens in (so it must be safe to call concurrently):

      %{step: :script | :stock | :voice | :assemble | :render | :brief,
        scene: 1..n | nil,
        status: :started | :done | :failed | :progress,
        ...}

  `:done` events carry a little detail (the number of scenes, the kind of footage found, the
  voice-over length); `:failed` carries `reason`; render `:progress` carries `done` and `total`
  (frames).

  ## Failures

  The first failure ends the run: `{:error, %{step: :stock, scene: 3, reason: ...}}`, so a
  failed video says which step of which scene broke. Nothing is rendered after a failure.
  """

  alias Retake.Pipeline.{Assemble, Script, Stock, Voice}
  alias Retake.Providers.Client
  alias Retake.Render

  @default_concurrency 3

  @type event :: %{
          required(:step) => atom(),
          required(:scene) => pos_integer() | nil,
          required(:status) => :started | :done | :failed | :progress,
          optional(atom()) => term()
        }
  @type failure :: %{step: atom(), scene: pos_integer() | nil, reason: term()}
  @type result :: %{id: String.t(), spec: map(), output: Path.t(), warnings: [String.t()]}

  @doc "A fresh video id: valid as a spec id and in a file name."
  @spec new_video_id() :: String.t()
  def new_video_id, do: "v-" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))

  @doc """
  Runs the pipeline. Options:

    * `:output` (required) - where the MP4 is written
    * `:video_id` - the spec's id (default `client.video_id`, else a new one)
    * `:on_event` - see "Events"
    * `:concurrency` - scenes prepared at once (default 3)
    * `:stock`, `:voice` - options for `Stock.find/3` and `Voice.generate/3`
    * `:render_timeout`, `:renderer` - passed to `Retake.Render.run/2`
  """
  @spec run(Client.t(), map(), keyword()) :: {:ok, result()} | {:error, failure()}
  def run(%Client{} = client, brief, opts) do
    emit = Keyword.get(opts, :on_event, fn _event -> :ok end)
    id = Keyword.get(opts, :video_id) || client.video_id || new_video_id()

    with {:ok, brief} <- step(:brief, nil, emit, fn -> Script.normalize_brief(brief) end),
         {:ok, script} <-
           step(:script, nil, emit, fn -> Script.generate(client, brief) end, &script_detail/1),
         {:ok, parts} <- prepare_scenes(client, script, emit, opts),
         {:ok, spec, assemble_warnings} <-
           step(:assemble, nil, emit, fn ->
             Assemble.build(%{id: id, brief: brief, script: script, scenes: parts})
           end),
         {:ok, rendered} <- render(client, spec, opts, emit) do
      warnings =
        script.warnings ++
          scene_warnings(parts) ++ assemble_warnings ++ rendered.warnings

      {:ok, %{id: id, spec: spec, output: rendered.path, warnings: warnings}}
    end
  end

  # --- the scenes, in parallel ---------------------------------------------------------------------

  defp prepare_scenes(client, script, emit, opts) do
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    script.scenes
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {scene, number} -> prepare(client, scene, number, emit, opts) end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, part}}, {:ok, parts} ->
        {:cont, {:ok, [part | parts]}}

      {:ok, {:error, failure}}, _acc ->
        {:halt, {:error, failure}}

      {:exit, reason}, _acc ->
        {:halt, {:error, %{step: :scenes, scene: nil, reason: {:crashed, reason}}}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      {:error, failure} -> {:error, failure}
    end
  end

  # One scene: its footage and its voice-over at the same time.
  defp prepare(client, scene, number, emit, opts) do
    stock =
      Task.async(fn ->
        step(
          :stock,
          number,
          emit,
          fn -> Stock.find(client, scene, Keyword.get(opts, :stock, [])) end,
          &stock_detail/1
        )
      end)

    voice =
      Task.async(fn ->
        step(
          :voice,
          number,
          emit,
          fn -> Voice.generate(client, scene, Keyword.get(opts, :voice, [])) end,
          &voice_detail/1
        )
      end)

    case {Task.await(stock, :infinity), Task.await(voice, :infinity)} do
      {{:ok, stock}, {:ok, voice}} -> {:ok, %{stock: stock, voice: voice}}
      {{:error, failure}, _voice} -> {:error, failure}
      {_stock, {:error, failure}} -> {:error, failure}
    end
  end

  # --- one step ---------------------------------------------------------------------------------------

  # Runs `fun`, announcing the start and the end. `fun` returns {:ok, value}, {:ok, value, extra}
  # or {:error, reason}; the result is passed on, an error wrapped with the step and the scene.
  # An exception becomes a failure too, so one bad scene cannot take the whole run down.
  defp step(name, scene, emit, fun, detail \\ fn _value -> %{} end) do
    emit.(%{step: name, scene: scene, status: :started})

    result =
      try do
        fun.()
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      end

    case result do
      {:ok, value} = ok ->
        emit.(Map.merge(%{step: name, scene: scene, status: :done}, detail.(value)))
        ok

      {:ok, value, _extra} = ok ->
        emit.(Map.merge(%{step: name, scene: scene, status: :done}, detail.(value)))
        ok

      {:error, reason} ->
        emit.(%{step: name, scene: scene, status: :failed, reason: reason})
        {:error, %{step: name, scene: scene, reason: reason}}
    end
  end

  defp script_detail(script), do: %{scenes: length(script.scenes), title: script.title}

  defp stock_detail(%{asset: asset, query: query}) do
    %{kind: asset["kind"], query: query, credit: asset["license"]["attribution"]}
  end

  defp voice_detail(%{duration_ms: duration}), do: %{duration_ms: duration}

  # --- rendering ---------------------------------------------------------------------------------------

  defp render(client, spec, opts, emit) do
    emit.(%{step: :render, scene: nil, status: :started})

    render_opts =
      [
        output: Keyword.fetch!(opts, :output),
        storage: client.storage,
        on_progress: fn done, total ->
          emit.(%{step: :render, scene: nil, status: :progress, done: done, total: total})
        end
      ] ++ render_options(opts)

    case Render.run(spec, render_opts) do
      {:ok, rendered} ->
        emit.(%{step: :render, scene: nil, status: :done, output: rendered.path})
        {:ok, rendered}

      {:error, error} ->
        emit.(%{step: :render, scene: nil, status: :failed, reason: error})
        {:error, %{step: :render, scene: nil, reason: error}}
    end
  end

  defp render_options(opts) do
    for {from, to} <- [render_timeout: :timeout, renderer: :renderer, base_dir: :base_dir],
        Keyword.has_key?(opts, from),
        do: {to, Keyword.fetch!(opts, from)}
  end

  defp scene_warnings(parts) do
    for {part, number} <- Enum.with_index(parts, 1),
        warning <- part.stock.warnings ++ part.voice.warnings,
        do: "scene #{number}: #{warning}"
  end
end
