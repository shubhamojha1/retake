defmodule Retake.Providers.Adapters.CloudflareWorkersAIImage do
  @moduledoc """
  The `cloudflare_workers_ai_image` adapter: text to image on Cloudflare Workers AI
  (FLUX.1 [schnell] and its relatives). Settings come from the provider in
  `config/providers.toml`: `model` (required, for example
  `"@cf/black-forest-labs/flux-1-schnell"`), `account_id_env` (the environment variable that
  holds the Cloudflare account id; default `"CLOUDFLARE_ACCOUNT_ID"`), `steps` (default 4, at
  most 8), `base_url` (default `"https://api.cloudflare.com/client/v4"`) and `timeout_ms`.
  The API token is the provider's `api_key_env`, sent as a bearer token.

  The request (string keys):

      %{"prompt" => "A dim bedroom at night, a phone glowing on a pillow, vertical shot."}

  Two kinds of model, told apart by the provider's settings:

    * FLUX.1 (`flux-1-schnell`): JSON with `steps`; always a square 1024x1024 picture (the
      service rejects a size). `normalize_request/2` fills `steps` in from the provider.
    * FLUX.2 (`flux-2-klein-4b`): a multipart form with `prompt`, `width` and `height`, no
      steps. Set `width` and `height` (each 256 to 2048) on the provider, for example 768 and
      1344 for a 9:16 picture, and `normalize_request/2` adds them to the request.

  Either way the filled-in values are part of the cache key and the asset's provenance. The
  output is `{:binary, image, "jpg" | "png"}`, checked to be an image whose size can be read
  (`Retake.Media.Image`). On the free plan a call costs nothing: usage is reported as
  `cost_usd: 0.0` and `units: %{"steps" => n}` or `%{"width" => w, "height" => h}`.

  The REST API wraps its answer as `{"result": {"image": "<base64>"}, "success": true}`; a bare
  `{"image": "<base64>"}` is accepted too.

  Errors: `{:http, status, message}`, `{:transport, reason}`, `{:unexpected_response, why}`,
  `{:bad_request, why}` (blank or too long a prompt, steps out of range) and
  `{:bad_provider_config, why}` (no token, model or account id).
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Media.Image
  alias Retake.Providers.Adapters.Http
  alias Retake.Providers.Provider

  @default_base_url "https://api.cloudflare.com/client/v4"
  @default_account_env "CLOUDFLARE_ACCOUNT_ID"
  @default_steps 4
  @max_steps 8
  @min_side 256
  @max_side 2048
  @max_prompt 2048
  @default_timeout 60_000
  @extensions %{"image/jpeg" => "jpg", "image/png" => "png"}

  @impl true
  def normalize_request(%Provider{} = provider, request) do
    case provider_size(provider) do
      {width, height} -> Map.merge(%{"width" => width, "height" => height}, request)
      nil -> Map.put_new(request, "steps", provider.options["steps"] || @default_steps)
    end
  end

  # A provider with both a width and a height makes pictures of that size (a FLUX.2 model).
  defp provider_size(%Provider{options: %{"width" => width, "height" => height}}),
    do: {width, height}

  defp provider_size(_provider), do: nil

  @impl true
  def call(%Provider{} = provider, api_key, request) do
    with {:ok, token} <- token(provider, api_key),
         {:ok, model} <- required(provider, "model"),
         {:ok, account} <- account_id(provider),
         {:ok, prompt} <- prompt(request["prompt"]),
         {:ok, shape} <- shape(provider, request) do
      provider
      |> http_request(account, model, body(prompt, shape), token)
      |> Req.request()
      |> handle(shape, token)
    end
  end

  # What kind of call this is. FLUX.1 takes JSON with `steps` and always makes a square picture;
  # FLUX.2 takes a multipart form with a `width` and a `height` and no steps. A request that has
  # a width and a height (`normalize_request/2` adds them from the provider) is a FLUX.2 one.
  defp shape(_provider, %{"width" => width, "height" => height}) do
    if side?(width) and side?(height) do
      {:ok, {:size, width, height}}
    else
      {:error,
       {:bad_request, "width and height must be whole numbers from #{@min_side} to #{@max_side}"}}
    end
  end

  defp shape(_provider, request)
       when is_map_key(request, "width") or is_map_key(request, "height") do
    {:error, {:bad_request, "give both width and height, or neither"}}
  end

  defp shape(provider, request) do
    with {:ok, steps} <- steps(request["steps"] || provider.options["steps"] || @default_steps) do
      {:ok, {:steps, steps}}
    end
  end

  defp side?(side), do: is_integer(side) and side >= @min_side and side <= @max_side

  defp body(prompt, {:steps, steps}), do: [json: %{"prompt" => prompt, "steps" => steps}]

  defp body(prompt, {:size, width, height}) do
    [form_multipart: [prompt: prompt, width: to_string(width), height: to_string(height)]]
  end

  defp units({:steps, steps}), do: %{"steps" => steps}
  defp units({:size, width, height}), do: %{"width" => width, "height" => height}

  # --- settings and request checks ------------------------------------------------------

  defp token(_provider, key) when is_binary(key) and key != "", do: {:ok, key}

  defp token(provider, _key) do
    {:error,
     {:bad_provider_config,
      "provider #{inspect(provider.name)} needs an api_key_env naming the Cloudflare API token"}}
  end

  defp required(provider, name) do
    case provider.options[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:bad_provider_config, "provider #{inspect(provider.name)} needs a #{name}"}}
    end
  end

  defp account_id(provider) do
    variable = provider.options["account_id_env"] || @default_account_env

    case variable |> System.get_env() |> to_string() |> String.trim() do
      "" ->
        {:error, {:bad_provider_config, "no Cloudflare account id: export #{variable}=..."}}

      account ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, account) do
          {:ok, account}
        else
          {:error,
           {:bad_provider_config, "#{variable} does not look like a Cloudflare account id"}}
        end
    end
  end

  defp prompt(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" ->
        {:error, {:bad_request, "prompt must not be blank"}}

      String.length(prompt) > @max_prompt ->
        {:error, {:bad_request, "prompt must be at most #{@max_prompt} characters"}}

      true ->
        {:ok, prompt}
    end
  end

  defp prompt(_other), do: {:error, {:bad_request, "the request needs a prompt"}}

  defp steps(steps) when is_integer(steps) and steps >= 1 and steps <= @max_steps,
    do: {:ok, steps}

  defp steps(_other) do
    {:error, {:bad_request, "steps must be a whole number from 1 to #{@max_steps}"}}
  end

  # --- request ----------------------------------------------------------------------------

  defp http_request(provider, account, model, body_options, token) do
    base = String.trim_trailing(provider.options["base_url"] || @default_base_url, "/")

    ([
       method: :post,
       url: "#{base}/accounts/#{account}/ai/run/#{model}",
       auth: {:bearer, token},
       receive_timeout: provider.options["timeout_ms"] || @default_timeout,
       retry: false
     ] ++ body_options)
    |> Keyword.merge(Http.options(__MODULE__))
    |> Req.new()
  end

  # --- response ---------------------------------------------------------------------------

  defp handle({:ok, %Req.Response{status: 200, body: body}}, shape, _token) do
    with {:ok, encoded} <- image_field(body),
         {:ok, bytes} <- decode(encoded),
         {:ok, %{mime: mime}} <- image(bytes) do
      {:ok, {:binary, bytes, Map.fetch!(@extensions, mime)},
       %{cost_usd: 0.0, units: units(shape)}}
    end
  end

  # Cloudflare's own error shape: {"success": false, "errors": [{"code": .., "message": ..}]}.
  defp handle(
         {:ok, %Req.Response{status: status, body: %{"errors" => [%{"message" => message} | _]}}},
         _shape,
         token
       )
       when status != 200 and is_binary(message) do
    {:error, {:http, status, message |> Http.redact(token) |> String.slice(0, 300)}}
  end

  defp handle(other, _shape, token), do: Http.failure(other, token)

  defp image_field(%{"result" => %{"image" => image}}) when is_binary(image) and image != "",
    do: {:ok, image}

  defp image_field(%{"image" => image}) when is_binary(image) and image != "", do: {:ok, image}
  defp image_field(_body), do: {:error, {:unexpected_response, "the reply had no image"}}

  defp decode(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:unexpected_response, "the image in the reply is not valid base64"}}
    end
  end

  defp image(bytes) do
    case Image.dimensions(bytes) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        {:error, {:unexpected_response, "the reply is not a readable image (#{reason})"}}
    end
  end
end
