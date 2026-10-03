defmodule Retake.Cache.Entry do
  @moduledoc """
  One cached provider call: what was asked, who answered, what it cost, and the
  result. This is also the provenance of the asset it produced (AGENTS.md rule 4;
  `provenance/1` gives the map a spec asset carries).

  `result` is `{:json, term}` or `{:asset, %{uri, content_hash, size}}`.
  """

  @capabilities ~w(llm tts stt stock music image video)
  @capability_atoms Map.new(@capabilities, fn name -> {name, String.to_atom(name)} end)

  @enforce_keys [
    :request_hash,
    :capability,
    :provider,
    :model,
    :request,
    :created_at,
    :cost,
    :result
  ]
  defstruct @enforce_keys

  @type result :: {:json, term()} | {:asset, Retake.Storage.ref()}
  @type cost :: %{amount: float(), currency: String.t(), units: map()}
  @type t :: %__MODULE__{
          request_hash: String.t(),
          capability: atom(),
          provider: String.t(),
          model: String.t(),
          request: map(),
          created_at: DateTime.t(),
          cost: cost(),
          result: result()
        }

  @doc "The provenance map of a spec asset (`spec/video.schema.json`, `$defs/provenance`)."
  @spec provenance(t()) :: map()
  def provenance(%__MODULE__{} = entry) do
    %{
      "source" => if(entry.capability == :stock, do: "stock", else: "generated"),
      "capability" => Atom.to_string(entry.capability),
      "provider" => entry.provider,
      "model" => entry.model,
      "request" => entry.request,
      "request_hash" => entry.request_hash,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "cost" => cost_json(entry.cost)
    }
  end

  @doc "The JSON-ready map written to the cache file."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = entry) do
    entry
    |> provenance()
    |> Map.delete("source")
    |> Map.put("result", result_json(entry.result))
  end

  @doc "Reads a decoded cache file back into an entry, or `:error` if it is not one."
  @spec from_json(term()) :: {:ok, t()} | :error
  def from_json(%{
        "request_hash" => request_hash,
        "capability" => capability,
        "provider" => provider,
        "model" => model,
        "request" => request,
        "created_at" => created_at,
        "cost" => cost,
        "result" => result
      })
      when is_binary(request_hash) and is_binary(provider) and is_binary(model) and
             is_map(request) do
    with {:ok, capability} <- Map.fetch(@capability_atoms, capability),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(created_at),
         {:ok, cost} <- cost_from_json(cost),
         {:ok, result} <- result_from_json(result) do
      {:ok,
       %__MODULE__{
         request_hash: request_hash,
         capability: capability,
         provider: provider,
         model: model,
         request: request,
         created_at: created_at,
         cost: cost,
         result: result
       }}
    else
      _ -> :error
    end
  end

  def from_json(_other), do: :error

  defp cost_json(%{amount: amount, currency: currency, units: units}) do
    %{"amount" => amount, "currency" => currency, "units" => units}
  end

  defp cost_from_json(%{"amount" => amount, "currency" => currency} = cost)
       when is_number(amount) and is_binary(currency) do
    {:ok, %{amount: amount * 1.0, currency: currency, units: Map.get(cost, "units", %{})}}
  end

  defp cost_from_json(_other), do: :error

  defp result_json({:json, value}), do: %{"type" => "json", "value" => value}

  defp result_json({:asset, %{uri: uri, content_hash: hash, size: size}}) do
    %{"type" => "asset", "uri" => uri, "content_hash" => hash, "size" => size}
  end

  defp result_from_json(%{"type" => "json", "value" => value}), do: {:ok, {:json, value}}

  defp result_from_json(%{
         "type" => "asset",
         "uri" => uri,
         "content_hash" => hash,
         "size" => size
       })
       when is_binary(uri) and is_binary(hash) and is_integer(size) do
    {:ok, {:asset, %{uri: uri, content_hash: hash, size: size}}}
  end

  defp result_from_json(_other), do: :error
end
