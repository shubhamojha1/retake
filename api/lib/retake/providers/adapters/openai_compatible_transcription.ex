defmodule Retake.Providers.Adapters.OpenAICompatibleTranscription do
  @moduledoc """
  The `openai_compatible_transcription` adapter: speech to text with word timings, for any
  service that speaks OpenAI's `/audio/transcriptions` API (Groq's Whisper, OpenAI, a local
  faster-whisper server). Settings come from the provider in `config/providers.toml`:
  `base_url` and `model` (required), `language` (optional default), `timeout_ms`. A key is
  sent as a bearer token if the provider has one.

  The request (string keys) names the audio by its storage URI; the adapter reads the file
  from the storage `Retake.Providers.Client` gives it, so the cache key holds the file's
  content hash, not its bytes:

      %{"audio" => "store://assets/<sha256>.wav", "language" => "en"}   # language optional

  `normalize_request/2` adds `"granularity" => "word"` (and the provider's `language`, if
  it has one). Only word timestamps are supported. The output is

      {:json, %{"language" => "english", "duration_ms" => 4520, "text" => "Hello there.",
                "words" => [%{"text" => "Hello", "start_ms" => 0, "end_ms" => 420}, ...]}}

  Words are trimmed and blank ones dropped; an end before its start is raised to the start.
  A reply with no `words` at all (a service that ignores word timestamps) is an error.

  Errors: `{:http, status, message}`, `{:transport, reason}`, `{:unexpected_response, why}`,
  `{:bad_request, why}` and `{:bad_provider_config, why}`. The API key is redacted from
  any echoed message (AGENTS.md rule 7).
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Providers.Adapters.Http
  alias Retake.Providers.Provider
  alias Retake.Storage

  @default_timeout 120_000
  @content_types %{
    "wav" => "audio/wav",
    "mp3" => "audio/mpeg",
    "flac" => "audio/flac",
    "ogg" => "audio/ogg",
    "m4a" => "audio/mp4",
    "webm" => "audio/webm"
  }

  @impl true
  def normalize_request(%Provider{} = provider, request) do
    defaults =
      %{"granularity" => "word", "language" => provider.options["language"]}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Map.merge(defaults, request)
  end

  @impl true
  def call(%Provider{}, _api_key, _request) do
    {:error,
     {:bad_request,
      "transcription reads an audio file from storage: call it through Retake.Providers.Client"}}
  end

  @impl true
  def call(%Provider{} = provider, api_key, request, %{storage: storage}) do
    with {:ok, base_url} <- required(provider, "base_url"),
         {:ok, model} <- required(provider, "model"),
         :ok <- granularity(request["granularity"]),
         {:ok, audio, extension} <- audio(storage, request["audio"]) do
      provider
      |> http_request(base_url, model, api_key, audio, extension, request["language"])
      |> Req.request()
      |> handle(api_key)
    end
  end

  defp required(provider, name) do
    case provider.options[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:bad_provider_config, "provider #{inspect(provider.name)} needs a #{name}"}}
    end
  end

  defp granularity(nil), do: :ok
  defp granularity("word"), do: :ok

  defp granularity(other),
    do: {:error, {:bad_request, "only word timestamps are supported, not #{inspect(other)}"}}

  defp audio(storage, uri) when is_binary(uri) do
    with {:ok, %{extension: extension}} <- parse(uri),
         {:ok, bytes} <- fetch(storage, uri) do
      {:ok, bytes, extension}
    end
  end

  defp audio(_storage, _other),
    do: {:error, {:bad_request, "the request needs an audio asset uri"}}

  defp parse(uri) do
    case Storage.parse_uri(uri) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, :invalid_uri} ->
        {:error, {:bad_request, "#{inspect(uri)} is not a store:// asset uri"}}
    end
  end

  defp fetch(storage, uri) do
    case Storage.fetch(storage, uri) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error, {:bad_request, "audio asset #{uri} cannot be read (#{inspect(reason)})"}}
    end
  end

  # --- request ----------------------------------------------------------------------

  defp http_request(provider, base_url, model, api_key, audio, extension, language) do
    form =
      [
        file:
          {audio,
           filename: "audio.#{extension}",
           content_type: Map.get(@content_types, extension, "application/octet-stream")},
        model: model,
        response_format: "verbose_json",
        "timestamp_granularities[]": "word"
      ] ++ if(is_binary(language), do: [language: language], else: [])

    [
      method: :post,
      url: String.trim_trailing(base_url, "/") <> "/audio/transcriptions",
      form_multipart: form,
      receive_timeout: provider.options["timeout_ms"] || @default_timeout,
      retry: false
    ]
    |> put_auth(api_key)
    |> Keyword.merge(Http.options(__MODULE__))
    |> Req.new()
  end

  defp put_auth(options, nil), do: options
  defp put_auth(options, key), do: Keyword.put(options, :auth, {:bearer, key})

  # --- response ---------------------------------------------------------------------

  defp handle({:ok, %Req.Response{status: 200, body: %{"words" => words} = body}}, _api_key)
       when is_list(words) do
    output =
      {:json,
       %{
         "language" => body["language"],
         "duration_ms" => seconds_to_ms(body["duration"]),
         "text" => body |> Map.get("text", "") |> to_string() |> String.trim(),
         "words" => normalize(words)
       }}

    {:ok, output, %{cost_usd: 0.0, units: units(body["duration"])}}
  end

  defp handle({:ok, %Req.Response{status: 200, body: body}}, api_key) do
    {:error,
     {:unexpected_response, "the reply has no word timestamps: " <> Http.message(body, api_key)}}
  end

  defp handle(other, api_key), do: Http.failure(other, api_key)

  defp normalize(words) do
    for word <- words,
        is_map(word),
        text <- [clean(word["word"])],
        text != "",
        is_number(word["start"]),
        is_number(word["end"]) do
      start_ms = round(word["start"] * 1000)

      %{
        "text" => text,
        "start_ms" => start_ms,
        "end_ms" => max(round(word["end"] * 1000), start_ms)
      }
    end
  end

  defp clean(text) when is_binary(text), do: String.trim(text)
  defp clean(_other), do: ""

  defp seconds_to_ms(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp seconds_to_ms(_other), do: nil

  defp units(seconds) when is_number(seconds), do: %{"seconds" => seconds}
  defp units(_other), do: %{}
end
