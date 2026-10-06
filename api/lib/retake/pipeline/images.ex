defmodule Retake.Pipeline.Images do
  @moduledoc """
  A scene's `image_prompt` becomes a generated image, stored and ready to use as a spec asset.
  Nothing here knows which service paints it: one provider call for the `image` capability,
  cached by the request (the same prompt is never painted, or paid for, twice).

  The asset's size is read from the stored bytes, and its provenance (source `generated`, the
  provider, the model, the prompt, the cost) comes from the cache entry, so the spec says how
  every picture was made (AGENTS.md rule 4). A picture that is not portrait is still usable, but
  the video is 9:16 and the renderer fits it with `cover`, so its sides are cropped: that is
  reported as a warning.

  Talks to providers only through `Retake.Providers.Client`.
  """

  alias Retake.Cache.Entry
  alias Retake.Media.Image
  alias Retake.Providers.Client
  alias Retake.Storage

  @type generated :: %{asset: map(), prompt: String.t(), warnings: [String.t()]}

  @doc """
  Makes the image for `scene` (a map with an `:image_prompt`, as `Retake.Pipeline.Script`
  returns it).

  Returns `{:ok, %{asset: asset, prompt: prompt, warnings: warnings}}` where `asset` is a spec
  asset (string keys), or an error: what `Retake.Providers.Client.call/4` returns
  (`{:all_providers_failed, _}`, `{:budget_exceeded, _}`, `{:capability_not_configured, :image}`),
  `{:bad_image, reason}` when the stored bytes are not an image, or
  `{:unexpected_image_result, result}`.
  """
  @spec generate(Client.t(), %{required(:image_prompt) => String.t(), optional(atom()) => term()}) ::
          {:ok, generated()} | {:error, term()}
  def generate(%Client{} = client, %{image_prompt: prompt}) when is_binary(prompt) do
    case Client.call(client, :image, %{"prompt" => prompt}) do
      {:ok, %Entry{result: {:asset, ref}} = entry, _outcome} ->
        describe(client, entry, ref, prompt)

      {:ok, entry, _outcome} ->
        {:error, {:unexpected_image_result, entry.result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp describe(client, entry, ref, prompt) do
    with {:ok, bytes} <- Storage.fetch(client.storage, ref.uri),
         {:ok, info} <- dimensions(bytes) do
      {:ok, %{asset: asset(entry, ref, info), prompt: prompt, warnings: warnings(info)}}
    end
  end

  defp dimensions(bytes) do
    case Image.dimensions(bytes) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, {:bad_image, reason}}
    end
  end

  defp asset(entry, ref, info) do
    %{
      "kind" => "image",
      "uri" => ref.uri,
      "content_hash" => ref.content_hash,
      "media" => %{"width" => info.width, "height" => info.height, "mime" => info.mime},
      "provenance" => Entry.provenance(entry),
      "license" => %{"name" => "AI-generated: #{entry.model}"}
    }
  end

  defp warnings(%{width: width, height: height}) when width >= height do
    ["the image is #{width}x#{height}, not portrait: the video crops its sides to fit 9:16"]
  end

  defp warnings(_info), do: []
end
