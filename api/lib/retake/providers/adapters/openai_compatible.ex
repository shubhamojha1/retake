defmodule Retake.Providers.Adapters.OpenAICompatible do
  @moduledoc """
  The `openai_compatible` adapter: chat completions for any service that speaks the
  OpenAI API (Groq, Ollama, OpenAI, ...). Settings come from the provider in
  `config/providers.toml`: `base_url` and `model` (required), `temperature`,
  `max_tokens`, `timeout_ms`, and `structured_output` (`"json_schema"` or
  `"json_object"`).

  The request is a map with string keys:

      %{
        "messages" => [%{"role" => "system" | "user" | "assistant", "content" => "..."}],
        "response_schema" => %{"name" => "script", "schema" => %{...JSON Schema...}}  # optional
      }

  `response_schema` asks for JSON: it becomes `response_format` in the way the
  provider's `structured_output` says. The output is
  `{:json, %{"content" => text, "finish_reason" => reason}}`; the caller parses and
  validates `content` (a model may wrap or break its JSON).

  Errors are `{:http, status, message}`, `{:transport, reason}`,
  `{:unexpected_response, body}` or `{:bad_provider_config, message}`. The API key
  never appears in one: if a service echoes it back, it is replaced with
  `[redacted]` (AGENTS.md rule 7).
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Providers.Adapters.Http
  alias Retake.Providers.Provider

  @default_timeout 60_000

  @impl true
  def call(%Provider{} = provider, api_key, request) do
    with {:ok, base_url} <- required(provider, "base_url"),
         {:ok, model} <- required(provider, "model") do
      provider
      |> http_request(base_url, model, api_key, request)
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

  # --- request ----------------------------------------------------------------------

  defp http_request(provider, base_url, model, api_key, request) do
    options =
      [
        method: :post,
        url: String.trim_trailing(base_url, "/") <> "/chat/completions",
        json: body(provider, model, request),
        receive_timeout: provider.options["timeout_ms"] || @default_timeout,
        retry: false
      ]
      |> put_auth(api_key)
      |> Keyword.merge(Http.options(__MODULE__))

    Req.new(options)
  end

  defp put_auth(options, nil), do: options
  defp put_auth(options, key), do: Keyword.put(options, :auth, {:bearer, key})

  defp body(provider, model, request) do
    %{"model" => model, "messages" => request["messages"]}
    |> put_option("temperature", provider.options["temperature"])
    |> put_option("max_tokens", provider.options["max_tokens"])
    |> put_response_format(provider.options["structured_output"], request["response_schema"])
  end

  defp put_option(body, _key, nil), do: body
  defp put_option(body, key, value), do: Map.put(body, key, value)

  defp put_response_format(body, "json_schema", %{"name" => name, "schema" => schema}) do
    Map.put(body, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{"name" => name, "schema" => schema}
    })
  end

  defp put_response_format(body, "json_object", %{}) do
    Map.put(body, "response_format", %{"type" => "json_object"})
  end

  defp put_response_format(body, _mode, _schema), do: body

  # --- response ---------------------------------------------------------------------

  defp handle(
         {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = body}},
         api_key
       ) do
    case choice do
      %{"message" => %{"content" => content}} when is_binary(content) ->
        output = {:json, %{"content" => content, "finish_reason" => choice["finish_reason"]}}
        {:ok, output, %{cost_usd: 0.0, units: units(body["usage"])}}

      _ ->
        unexpected(body, api_key)
    end
  end

  defp handle({:ok, %Req.Response{status: 200, body: body}}, api_key),
    do: unexpected(body, api_key)

  # Any other status, and transport failures.
  defp handle(failure, api_key), do: Http.failure(failure, api_key)

  defp unexpected(body, api_key),
    do: {:error, {:unexpected_response, Http.message(body, api_key)}}

  # ponytail: token counts only; cost is 0.0 because the free profile is the target. A paid
  # model needs a price table to turn tokens into dollars.
  defp units(%{} = usage) do
    for key <- ["prompt_tokens", "completion_tokens"], is_integer(usage[key]), into: %{} do
      {key, usage[key]}
    end
  end

  defp units(_other), do: %{}
end
