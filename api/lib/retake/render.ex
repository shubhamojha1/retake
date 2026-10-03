defmodule Retake.Render do
  @moduledoc """
  Runs the Rust renderer (`crates/retake_render`) as a separate OS process through
  a Port (decision D4, AGENTS.md rule 8): a renderer crash cannot take the BEAM
  down, and Elixir never links a media library.

  `run/2` writes the spec to a temporary file, with every `store://` uri replaced
  by the real file path from the storage (the renderer only reads `file://`),
  starts the renderer, and reads its output line by line:

      progress <done>/<total>     forwarded to `:on_progress`
      done <path>                 the finished file
      warning: <text>             collected and returned
      error: <text>               the failure message
      anything else               FFmpeg's own messages, kept to explain a failure
  """

  alias Retake.Storage

  @default_timeout 600_000
  @max_log_lines 20
  @max_log_line 500

  @type error :: %{
          kind: :renderer_not_found | :asset_not_found | :render_failed | :timeout,
          message: String.t(),
          warnings: [String.t()]
        }

  @doc "The configured renderer binary (`RETAKE_RENDERER_BIN`, else the build for this environment)."
  @spec renderer_bin() :: Path.t()
  def renderer_bin, do: Application.fetch_env!(:retake, :renderer_bin)

  @doc """
  Renders `spec` (a decoded spec map) to `:output`.

  Options:

    * `:output` (required) - where the MP4 is written
    * `:storage` - a `Retake.Storage` to resolve `store://` uris (needed if the spec has any)
    * `:base_dir` - the renderer's working directory; relative `file://` paths resolve
      against it (default: the current directory)
    * `:on_progress` - `fn done, total -> ... end`, called in the calling process
    * `:timeout` - milliseconds before the renderer is killed (default 10 minutes)
    * `:renderer` - the binary to run (default: `renderer_bin/0`)
  """
  @spec run(map(), keyword()) ::
          {:ok, %{path: String.t(), warnings: [String.t()]}} | {:error, error()}
  def run(spec, opts) when is_map(spec) do
    output = Keyword.fetch!(opts, :output)
    renderer = Keyword.get_lazy(opts, :renderer, &renderer_bin/0)

    with :ok <- check_binary(renderer),
         {:ok, spec} <- resolve_uris(spec, opts[:storage]) do
      spec_path = write_spec(spec)

      try do
        execute(renderer, spec_path, output, opts)
      after
        File.rm(spec_path)
      end
    end
  end

  # --- before starting ------------------------------------------------------------

  defp check_binary(renderer) do
    if File.regular?(renderer) do
      :ok
    else
      {:error,
       error(
         :renderer_not_found,
         "renderer binary not found at #{renderer} (build it with `cargo build -p retake_render`)"
       )}
    end
  end

  defp resolve_uris(spec, storage) do
    assets = if is_map(spec["assets"]), do: spec["assets"], else: %{}

    Enum.reduce_while(assets, {:ok, spec}, fn {id, asset}, {:ok, spec} ->
      case asset do
        %{"uri" => "store://" <> _ = uri} ->
          case local_file(storage, id, uri) do
            {:ok, path} -> {:cont, {:ok, put_in(spec, ["assets", id, "uri"], "file://" <> path)}}
            {:error, message} -> {:halt, {:error, error(:asset_not_found, message)}}
          end

        _ ->
          {:cont, {:ok, spec}}
      end
    end)
  end

  defp local_file(nil, id, uri) do
    {:error, "asset #{inspect(id)} uses #{uri} but no :storage was given to resolve it"}
  end

  defp local_file(storage, id, uri) do
    case Storage.local_path(storage, uri) do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} ->
        {:error, "asset #{inspect(id)}: #{uri} is not in the storage (#{reason})"}
    end
  end

  defp write_spec(spec) do
    name =
      "retake-spec-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false) <> ".json"

    path = Path.join(System.tmp_dir!(), name)
    File.write!(path, Jason.encode!(spec))
    path
  end

  # --- running ------------------------------------------------------------------------

  defp execute(renderer, spec_path, output, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4096},
      {:args, [spec_path, "-o", output]},
      {:cd, Keyword.get_lazy(opts, :base_dir, &File.cwd!/0)}
    ]

    try do
      Port.open({:spawn_executable, renderer}, port_opts)
    rescue
      e in ErlangError ->
        {:error, error(:renderer_not_found, "cannot start #{renderer}: #{inspect(e.original)}")}
    else
      port ->
        state = %{
          port: port,
          partial: "",
          warnings: [],
          log: [],
          error: nil,
          done: nil,
          on_progress: Keyword.get(opts, :on_progress, fn _done, _total -> :ok end)
        }

        loop(state, System.monotonic_time(:millisecond) + timeout, timeout)
    end
  end

  defp loop(%{port: port} = state, deadline, timeout) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        state = handle_line(%{state | partial: ""}, state.partial <> chunk)
        loop(state, deadline, timeout)

      {^port, {:data, {:noeol, chunk}}} ->
        loop(%{state | partial: state.partial <> chunk}, deadline, timeout)

      {^port, {:exit_status, status}} ->
        state = if state.partial == "", do: state, else: handle_line(state, state.partial)
        finish(state, status)
    after
      remaining -> time_out(state, timeout)
    end
  end

  defp handle_line(state, "progress " <> counts = line) do
    with [done, total] <- String.split(counts, "/"),
         {done, ""} <- Integer.parse(done),
         {total, ""} <- Integer.parse(total) do
      state.on_progress.(done, total)
      state
    else
      _ -> log(state, line)
    end
  end

  defp handle_line(state, "done " <> path), do: %{state | done: path}
  defp handle_line(state, "warning: " <> text), do: %{state | warnings: [text | state.warnings]}
  defp handle_line(state, "error: " <> text), do: %{state | error: text}
  defp handle_line(state, line), do: log(state, line)

  defp log(state, line) do
    line = String.slice(line, 0, @max_log_line)
    %{state | log: Enum.take([line | state.log], @max_log_lines)}
  end

  # --- finishing -----------------------------------------------------------------------

  defp finish(%{done: path} = state, 0) when is_binary(path) do
    {:ok, %{path: path, warnings: Enum.reverse(state.warnings)}}
  end

  defp finish(state, status) do
    message =
      cond do
        state.error -> state.error
        status == 0 -> "the renderer exited without reporting an output file" <> log_suffix(state)
        true -> "the renderer exited with status #{status}" <> log_suffix(state)
      end

    {:error, error(:render_failed, message, state.warnings)}
  end

  defp log_suffix(%{log: []}), do: ""
  defp log_suffix(%{log: log}), do: ": " <> (log |> Enum.reverse() |> Enum.join("; "))

  # Closing a Port does not stop the OS process, so kill it first.
  defp time_out(state, timeout) do
    case Port.info(state.port, :os_pid) do
      {:os_pid, pid} -> :os.cmd(~c"kill -KILL #{pid}")
      _ -> :ok
    end

    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    flush(state.port)

    {:error,
     error(
       :timeout,
       "the renderer did not finish within #{timeout} ms and was killed",
       state.warnings
     )}
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  # `warnings` arrive newest first from the state; callers pass [] before the renderer runs.
  defp error(kind, message, warnings \\ []) do
    %{kind: kind, message: message, warnings: Enum.reverse(warnings)}
  end
end
