defmodule Retake.Providers.Adapters.Http do
  @moduledoc """
  What the HTTP adapters share: extra `Req` options from config (tests point each
  adapter at its own `Req.Test` stub), and turning a failed response into an error
  that never contains the API key (AGENTS.md rule 7).
  """

  @max_message 300

  @doc """
  Extra `Req` options for `adapter`, from `config :retake, :req_options, %{Module => [..]}`.
  Empty outside tests.
  """
  @spec options(module()) :: keyword()
  def options(adapter) do
    :retake |> Application.get_env(:req_options, %{}) |> Map.get(adapter, [])
  end

  @doc """
  The error for a response that is not the success the caller handles:
  `{:http, status, message}` or `{:transport, reason}`.
  """
  @spec failure({:ok, Req.Response.t()} | {:error, term()}, String.t() | nil) ::
          {:error, {:http, integer(), String.t()} | {:transport, term()}}
  def failure({:ok, %Req.Response{status: status, body: body}}, api_key) do
    {:error, {:http, status, message(body, api_key)}}
  end

  def failure({:error, %{reason: reason}}, _api_key), do: {:error, {:transport, reason}}

  def failure({:error, other}, api_key) do
    {:error, {:transport, other |> inspect() |> redact(api_key) |> truncate()}}
  end

  @doc "A short, key-free description of a response body, for an error."
  @spec message(term(), String.t() | nil) :: String.t()
  def message(%{"error" => %{"message" => message}}, api_key) when is_binary(message) do
    message |> redact(api_key) |> truncate()
  end

  def message(%{"error" => message}, api_key) when is_binary(message) do
    message |> redact(api_key) |> truncate()
  end

  def message(body, api_key) when is_binary(body) do
    # A body the caller did not decode (a download, an audio reply) may still be a JSON error.
    case Jason.decode(body) do
      {:ok, %{"error" => _} = decoded} -> message(decoded, api_key)
      _ -> body |> redact(api_key) |> truncate()
    end
  end

  def message(body, api_key), do: body |> inspect() |> redact(api_key) |> truncate()

  @doc false
  def redact(text, key) when is_binary(key) and key != "",
    do: String.replace(text, key, "[redacted]")

  def redact(text, _key), do: text

  defp truncate(text), do: String.slice(text, 0, @max_message)
end
