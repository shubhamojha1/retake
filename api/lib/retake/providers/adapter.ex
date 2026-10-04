defmodule Retake.Providers.Adapter do
  @moduledoc """
  What a provider adapter implements: speak one service's API and return its answer
  in the shape the rest of Retake understands.

  The adapter is handed the provider (its settings are in `provider.options`), the
  API key read from the environment just now (or `nil`) and the request. It returns
  the output, `{:json, term}` or `{:binary, bytes, extension}`, and what the call
  used: `:cost_usd` (charged to the budget) and `:units` (tokens, characters,
  seconds, recorded in the asset's provenance).

  Pipeline code never calls an adapter: it goes through `Retake.Providers.Client`
  (AGENTS.md rules 5 and 9).
  """

  alias Retake.Providers.Provider

  @type output :: {:json, term()} | {:binary, binary(), String.t()}
  @type usage :: %{optional(:cost_usd) => number(), optional(:units) => map()}

  @callback call(provider :: Provider.t(), api_key :: String.t() | nil, request :: map()) ::
              {:ok, output(), usage()} | {:error, term()}

  @doc """
  Optional. Fills in what the request leaves out from the provider's own settings (a
  voice, a speed). The result is what gets sent, and what the cache key and the asset's
  provenance are made from, so changing a setting changes the key instead of silently
  serving an answer made with the old one. Must be pure and idempotent.
  """
  @callback normalize_request(provider :: Provider.t(), request :: map()) :: map()

  @optional_callbacks normalize_request: 2
end
