defmodule Mix.Tasks.Retake.Image do
  @shortdoc "Makes an image for a prompt with the profile's image provider"

  @moduledoc """
  Makes one image for real: sends the prompt to the image provider of the chosen profile,
  stores the picture in `.retake/store` and tells you where it is, how big it is and whether it
  came from the cache.

      mix retake.image "a dim bedroom at night, a phone glowing on a pillow, vertical shot"
      mix retake.image --steps 8 "a calm sea at sunrise, vertical shot, soft light"

  Needs `config/providers.toml` with an `image` slot in the profile (see
  `config/providers.example.toml`) and, for Cloudflare, `CLOUDFLARE_API_TOKEN` and
  `CLOUDFLARE_ACCOUNT_ID` in your environment.

  Options:

    * `--steps N`     how many diffusion steps, 1 to 8 (default: the provider's setting, 4);
      for FLUX.1 models only
    * `--width W --height H`  the picture size, 256 to 2048 each (default: the provider's
      setting); for FLUX.2 models only, for example `--width 1080 --height 1920`
    * `--force`       ask the provider again even if the answer is in the cache
    * `--profile NAME`, `--config PATH` as for `mix help retake.script`

  A repeated prompt is answered from the cache: no call is made and no allowance is used.
  A video is 9:16, so the size printed here tells you how much of a picture `cover` keeps.
  """

  use Mix.Task

  alias Retake.Cache.Entry
  alias Retake.CLI
  alias Retake.Media.Image
  alias Retake.Providers
  alias Retake.Providers.Client
  alias Retake.Storage

  @switches [
    profile: :string,
    config: :string,
    steps: :integer,
    width: :integer,
    height: :integer,
    force: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or words == [] do
      Mix.raise(
        ~s|usage: mix retake.image [options] "image prompt"   (see mix help retake.image)|
      )
    end

    Mix.Task.run("app.config")
    CLI.start_services()

    path = opts[:config] || CLI.default_config_path()

    case Client.from_file(path, profile: opts[:profile]) do
      {:ok, client} -> generate(client, Enum.join(words, " "), opts)
      {:error, reason} -> Mix.raise(CLI.describe(reason, path))
    end
  end

  defp generate(client, prompt, opts) do
    case Providers.resolve(client.config, client.profile, :image) do
      {:ok, providers} ->
        names = Enum.map_join(providers, ", then ", & &1.name)
        Mix.shell().info("profile #{client.profile}, image: #{names}")

      {:error, {:capability_not_configured, :image}} ->
        Mix.raise(
          "profile #{client.profile} has no image provider: add an `image` slot " <>
            "(see config/providers.example.toml)"
        )

      {:error, reason} ->
        Mix.raise(CLI.describe(reason, nil))
    end

    request =
      %{"prompt" => prompt}
      |> put_opt("steps", opts[:steps])
      |> put_opt("width", opts[:width])
      |> put_opt("height", opts[:height])

    case Client.call(client, :image, request, force: opts[:force] || false) do
      {:ok, %Entry{result: {:asset, ref}} = entry, outcome} -> print(client, entry, ref, outcome)
      {:ok, entry, _outcome} -> Mix.raise("unexpected result: #{inspect(entry.result)}")
      {:error, reason} -> Mix.raise(CLI.describe(reason, nil))
    end
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, value)

  defp print(client, entry, ref, outcome) do
    shell = Mix.shell()

    shell.info("\nprompt:    #{entry.request["prompt"]}")
    shell.info("settings:  #{inspect(Map.delete(entry.request, "prompt"))}")
    shell.info("provider:  #{entry.provider} (#{entry.model})")

    shell.info(
      if outcome == :hit,
        do: "answered from the cache: no call was made",
        else: "made just now (cost #{entry.cost.amount} #{entry.cost.currency})"
    )

    with {:ok, bytes} <- Storage.fetch(client.storage, ref.uri),
         {:ok, %{width: width, height: height, mime: mime}} <- Image.dimensions(bytes) do
      shell.info("size:      #{width}x#{height} #{mime}, #{byte_size(bytes)} bytes")

      if width >= height do
        # Cover fit scales the picture to fill the frame height; the frame is 1080 wide for 1920 tall.
        share = round(100 * (1080 / 1920) * height / width)

        shell.info(
          "note:      not portrait: cover fit on a 1080x1920 video shows about #{share}% of its width"
        )
      end
    end

    shell.info("stored as: #{ref.uri}")

    case Storage.local_path(client.storage, ref.uri) do
      {:ok, file} ->
        shell.info("file:      #{file}")
        if windows = windows_path(file), do: shell.info("from Windows: #{windows}")

      {:error, _} ->
        :ok
    end
  end

  # Inside WSL the same file is reachable from Windows at \\wsl$\<distro>\<path>.
  defp windows_path(file) do
    if distro = System.get_env("WSL_DISTRO_NAME") do
      "\\\\wsl$\\#{distro}" <> String.replace(file, "/", "\\")
    end
  end
end
