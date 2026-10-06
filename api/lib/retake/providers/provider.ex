defmodule Retake.Providers.Provider do
  @moduledoc """
  One configured provider: a named way of doing one capability (`config/providers.toml`).

  The struct never holds an API key. It holds the *name* of the environment
  variable (`api_key_env`); the key is read at call time by `api_key/2` and handed
  straight to the adapter (AGENTS.md rule 7).
  """

  @enforce_keys [:name, :capability, :adapter]
  defstruct [:name, :capability, :adapter, api_key_env: nil, rate_limit: %{}, options: %{}]

  @type capability :: :llm | :tts | :stt | :stock | :music | :image | :any

  @type t :: %__MODULE__{
          name: String.t(),
          capability: capability(),
          adapter: String.t(),
          api_key_env: String.t() | nil,
          rate_limit: %{atom() => pos_integer()},
          options: %{String.t() => term()}
        }

  @doc """
  The provider's API key from `env` (a map of variable name to value; `nil` means the
  real environment). A provider with no `api_key_env` needs no key and gets `nil`.
  """
  @spec api_key(t(), %{String.t() => String.t()} | nil) ::
          {:ok, String.t() | nil} | {:error, {:missing_env, String.t()}}
  def api_key(%__MODULE__{api_key_env: nil}, _env), do: {:ok, nil}

  def api_key(%__MODULE__{api_key_env: variable}, env) do
    case get_env(env, variable) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:missing_env, variable}}, else: {:ok, value}

      _ ->
        {:error, {:missing_env, variable}}
    end
  end

  @doc false
  def get_env(nil, name), do: System.get_env(name)
  def get_env(env, name) when is_map(env), do: Map.get(env, name)
end
