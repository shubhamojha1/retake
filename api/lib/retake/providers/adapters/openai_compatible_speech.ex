defmodule Retake.Providers.Adapters.OpenAICompatibleSpeech do
  @moduledoc """
  The `openai_compatible_speech` adapter: text to speech for any service that speaks
  OpenAI's `/audio/speech` API (Kokoro-FastAPI, OpenAI, ...). Settings come from the
  provider in `config/providers.toml`: `base_url` and `model` (required), `voice`,
  `speed`, `format` (default `"wav"`; `wav`, `mp3`, `flac`, `opus`, `aac` or `pcm`),
  `timeout_ms`. A key is sent as a bearer token if the provider has one (Kokoro needs none).

  The request (string keys):

      %{"text" => "What the narrator says.", "voice" => "af_heart", "speed" => 1.0}

  `voice` and `speed` are optional in the request: `normalize_request/2` fills them in
  from the provider's settings, so they are part of the cache key and the asset's
  provenance (changing the voice in the config does not serve audio made with the old
  one). The output is `{:binary, audio, format}`; for `wav` the bytes are checked to be
  a WAV file (the pipeline reads their duration from the header).

  Errors: `{:http, status, message}`, `{:transport, reason}`, `{:unexpected_response, why}`,
  `{:bad_request, why}` (no text, text too long, no voice) and `{:bad_provider_config, why}`.
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Providers.Adapters.Http
  alias Retake.Providers.Provider

  @default_timeout 120_000
  @default_format "wav"
  @formats ["wav", "mp3", "flac", "opus", "aac", "pcm"]
  @max_text 4096

  @impl true
  def normalize_request(%Provider{} = provider, request) do
    defaults =
      %{"voice" => provider.options["voice"], "speed" => provider.options["speed"]}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.merge(defaults, request)
  end

  @impl true
  def call(%Provider{} = provider, api_key, request) do
    with {:ok, base_url} <- required(provider, "base_url"),
         {:ok, model} <- required(provider, "model"),
         {:ok, format} <- format(provider),
         {:ok, text} <- text(request["text"]),
         {:ok, voice} <- voice(request["voice"]) do
      body = speech_body(model, text, voice, request["speed"], format)

      provider
      |> http_request(base_url, body, api_key)
      |> Req.request()
      |> handle(format, text, api_key)
    end
  end

  defp required(provider, name) do
    case provider.options[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:bad_provider_config, "provider #{inspect(provider.name)} needs a #{name}"}}
    end
  end

  defp format(provider) do
    case provider.options["format"] || @default_format do
      format when format in @formats ->
        {:ok, format}

      other ->
        {:error,
         {:bad_provider_config,
          "format #{inspect(other)} is not one of #{Enum.join(@formats, ", ")}"}}
    end
  end

  defp text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" ->
        {:error, {:bad_request, "text must not be blank"}}

      String.length(text) > @max_text ->
        {:error, {:bad_request, "text must be at most #{@max_text} characters"}}

      true ->
        {:ok, text}
    end
  end

  defp text(_other), do: {:error, {:bad_request, "the request needs text"}}

  defp voice(voice) when is_binary(voice) and voice != "", do: {:ok, voice}

  defp voice(_other) do
    {:error, {:bad_request, "no voice: set voice on the provider or in the request"}}
  end

  # --- request ----------------------------------------------------------------------

  defp speech_body(model, text, voice, speed, format) do
    %{"model" => model, "input" => text, "voice" => voice, "response_format" => format}
    |> then(fn body -> if is_number(speed), do: Map.put(body, "speed", speed), else: body end)
  end

  defp http_request(provider, base_url, body, api_key) do
    [
      method: :post,
      url: String.trim_trailing(base_url, "/") <> "/audio/speech",
      json: body,
      receive_timeout: provider.options["timeout_ms"] || @default_timeout,
      retry: false,
      decode_body: false
    ]
    |> put_auth(api_key)
    |> Keyword.merge(Http.options(__MODULE__))
    |> Req.new()
  end

  defp put_auth(options, nil), do: options
  defp put_auth(options, key), do: Keyword.put(options, :auth, {:bearer, key})

  # --- response ---------------------------------------------------------------------

  defp handle({:ok, %Req.Response{status: 200, body: audio}}, format, text, _api_key)
       when is_binary(audio) and byte_size(audio) > 0 do
    if format == "wav" and not wav?(audio) do
      {:error, {:unexpected_response, "asked for a WAV file but the reply is not one"}}
    else
      {:ok, {:binary, audio, format},
       %{cost_usd: 0.0, units: %{"characters" => String.length(text)}}}
    end
  end

  defp handle({:ok, %Req.Response{status: 200}}, _format, _text, _api_key) do
    {:error, {:unexpected_response, "the reply had no audio"}}
  end

  defp handle(other, _format, _text, api_key), do: Http.failure(other, api_key)

  defp wav?(<<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>), do: true
  defp wav?(_other), do: false
end
