defmodule Mix.Tasks.Retake.Stock do
  @shortdoc "Finds and downloads stock footage or a photo for a search phrase"

  @moduledoc """
  Runs the stock step of the pipeline for real: searches the stock services of the
  chosen profile, picks the best clip or photo, downloads it into `.retake/store`
  and tells you where it is.

      mix retake.stock "steaming tea cup closeup"
      mix retake.stock --narration "Tea is packed with antioxidants and calms the mind." "tea leaves"

  Needs `config/providers.toml` and an API key for at least one stock service, in
  your environment (`PIXABAY_API_KEY` for Pixabay, `PEXELS_API_KEY` for Pexels). A
  service without a key is skipped and the next one in the profile is tried.

  Options:

    * `--narration TEXT`  what the narrator will say in this scene: a clip should run as
      long as the narration, so a longer text prefers longer clips
    * `--min-width N`     smallest short side, in pixels, that counts as big enough (default 1080)
    * `--profile NAME`, `--config PATH` as for `mix help retake.script`
    * `--json`            print the spec asset as JSON

  A repeated search is answered from the cache; the file is never downloaded twice.
  """

  use Mix.Task

  alias Retake.CLI
  alias Retake.Pipeline.Stock
  alias Retake.Providers
  alias Retake.Providers.Client
  alias Retake.Storage

  @switches [
    profile: :string,
    config: :string,
    narration: :string,
    min_width: :integer,
    json: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or words == [] do
      Mix.raise(
        ~s|usage: mix retake.stock [options] "search phrase"   (see mix help retake.stock)|
      )
    end

    Mix.Task.run("app.config")
    CLI.start_services()

    path = opts[:config] || CLI.default_config_path()

    case Client.from_file(path, profile: opts[:profile]) do
      {:ok, client} -> find(client, Enum.join(words, " "), opts)
      {:error, reason} -> Mix.raise(CLI.describe(reason, path))
    end
  end

  defp find(client, query, opts) do
    {:ok, providers} = Providers.resolve(client.config, client.profile, :stock)
    names = Enum.map_join(providers, ", then ", & &1.name)
    Mix.shell().info("profile #{client.profile}, stock: #{names}")

    scene = %{narration: opts[:narration] || "", visual_query: query}
    find_opts = if opts[:min_width], do: [min_width: opts[:min_width]], else: []

    case Stock.find(client, scene, find_opts) do
      {:ok, found} -> print(client, found, opts[:json])
      {:error, reason} -> Mix.raise(CLI.describe(reason, nil))
    end
  end

  defp print(_client, %{asset: asset}, true) do
    Mix.shell().info(Jason.encode!(asset, pretty: true))
  end

  defp print(client, %{asset: asset, query: query, warnings: warnings}, _json) do
    shell = Mix.shell()
    media = asset["media"]
    size = "#{media["width"]}x#{media["height"]}"

    length =
      if media["duration_ms"], do: "  #{Float.round(media["duration_ms"] / 1000, 1)} s", else: ""

    shell.info("\nsearched for: #{query}")
    shell.info("found:        #{asset["kind"]}  #{size}#{length}")
    shell.info("credit:       #{asset["license"]["attribution"]}")
    shell.info("licence:      #{asset["license"]["name"]}")

    if asset["license"]["source_url"],
      do: shell.info("page:         #{asset["license"]["source_url"]}")

    shell.info("stored as:    #{asset["uri"]}")

    case Storage.local_path(client.storage, asset["uri"]) do
      {:ok, file} ->
        shell.info("file:         #{file}")
        if windows = windows_path(file), do: shell.info("from Windows:  #{windows}")

      {:error, _} ->
        :ok
    end

    for warning <- warnings, do: shell.info("\nwarning: #{warning}")
  end

  # Inside WSL the same file is reachable from Windows at \\wsl$\<distro>\<path>.
  defp windows_path(file) do
    if distro = System.get_env("WSL_DISTRO_NAME") do
      "\\\\wsl$\\#{distro}" <> String.replace(file, "/", "\\")
    end
  end
end
