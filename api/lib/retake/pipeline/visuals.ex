defmodule Retake.Pipeline.Visuals do
  @moduledoc """
  Step 2 of the pipeline: the picture for a scene. A generated image when the profile has an
  image provider and the scene has an `image_prompt` (`Retake.Pipeline.Images`); stock footage
  or a photo otherwise (`Retake.Pipeline.Stock`).

  An image failure never fails the scene: whatever goes wrong (a refusal, a rate limit, a spent
  budget, a bad reply), the scene falls back to stock, with a warning saying why. The two cases
  that are a choice, not a failure, fall back silently: the profile has no image provider, or
  the provider has no API key set (a user with no Cloudflare account should not see a warning
  on every scene).

  Returns the same shape the stock step does, plus where the picture came from:

      %{asset: spec_asset, query: "...", source: :generated | :stock,
        prompt: "..." | nil, warnings: [...]}

  Talks to providers only through `Retake.Providers.Client` (via the two steps it joins).
  """

  alias Retake.CLI
  alias Retake.Pipeline.{Images, Stock}
  alias Retake.Providers
  alias Retake.Providers.Client

  @type found :: %{
          asset: map(),
          query: String.t(),
          source: :generated | :stock,
          prompt: String.t() | nil,
          warnings: [String.t()]
        }

  @doc """
  Finds or makes the picture for `scene` (`%{narration, visual_query}` and optionally
  `image_prompt`, as `Retake.Pipeline.Script` returns them). `stock_opts` go to
  `Retake.Pipeline.Stock.find/3`.

  Returns `{:ok, found}`, or the stock step's error (`{:no_stock_found, queries}` or a provider
  error) when no picture could be had at all.
  """
  @spec find(Client.t(), map(), keyword()) :: {:ok, found()} | {:error, term()}
  def find(%Client{} = client, scene, stock_opts \\ []) do
    case Map.get(scene, :image_prompt) do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) == "" do
          stock(client, scene, stock_opts, [])
        else
          generated_or_stock(client, scene, stock_opts)
        end

      _none ->
        stock(client, scene, stock_opts, [])
    end
  end

  defp generated_or_stock(client, scene, stock_opts) do
    case Images.generate(client, scene) do
      {:ok, %{asset: asset, prompt: prompt, warnings: warnings}} ->
        {:ok,
         %{
           asset: asset,
           query: scene.visual_query,
           source: :generated,
           prompt: prompt,
           warnings: fallback_notice(client, asset) ++ warnings
         }}

      {:error, reason} ->
        stock(client, scene, stock_opts, fallback_warnings(reason))
    end
  end

  defp stock(client, scene, stock_opts, warnings) do
    with {:ok, found} <- Stock.find(client, scene, stock_opts) do
      {:ok,
       %{
         asset: found.asset,
         query: found.query,
         source: :stock,
         prompt: nil,
         warnings: warnings ++ found.warnings
       }}
    end
  end

  # The provider layer falls back silently (the first image provider timed out, say), so say so
  # when the picture is not from the first choice.
  defp fallback_notice(client, asset) do
    with {:ok, [first | _]} <- Providers.resolve(client.config, client.profile, :image),
         used when used != first.name <- asset["provenance"]["provider"] do
      ["the picture came from #{used}, not from the first image provider (#{first.name})"]
    else
      _ -> []
    end
  end

  # Not configured, or configured without a key: stock only, nothing to say.
  defp fallback_warnings({:capability_not_configured, :image}), do: []

  defp fallback_warnings({:all_providers_failed, attempts} = reason) do
    if Enum.all?(attempts, &match?(%{reason: {:missing_env, _}}, &1)),
      do: [],
      else: [warning(reason)]
  end

  defp fallback_warnings(reason), do: [warning(reason)]

  defp warning(reason) do
    # A provider's error text can run to pages: keep the start of it, which says what went wrong.
    why =
      reason
      |> CLI.describe(nil)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, 200)

    "the image could not be made (#{why}); stock footage used instead"
  end
end
