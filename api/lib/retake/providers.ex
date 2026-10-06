defmodule Retake.Providers do
  @moduledoc """
  The provider layer: resolves a capability to its providers for a profile and
  runs a call against them with fallbacks, rate limits and budget caps.

  Pipeline code calls `run/5` with a function that does the actual work; it never
  talks to a provider (or an HTTP client) directly (AGENTS.md rules 5 and 9). The
  adapters themselves arrive with the features that need them (F10 to F12).

  The function passed to `run/5` receives the provider and its API key (or `nil`)
  and returns `{:ok, result, usage}` (`usage` is a map, `:cost_usd` is charged to
  the budget) or `{:error, reason}`.
  """

  alias Retake.Providers.{Config, Provider, Usage}

  @capabilities [:llm, :tts, :stt, :stock, :music, :image]

  @type attempt :: %{provider: String.t(), reason: term()}

  @doc """
  The providers for `capability` in `profile`: the primary first, then the fallbacks. Every
  profile covers every capability except `:image`; a profile with no `image` slot has no
  image provider (`{:capability_not_configured, :image}`).
  """
  @spec resolve(Config.t(), String.t(), atom()) ::
          {:ok, [Provider.t()]}
          | {:error,
             {:unknown_profile, String.t()}
             | {:unknown_capability, atom()}
             | {:capability_not_configured, atom()}}
  def resolve(%Config{} = config, profile, capability) do
    with {:ok, slots} <- fetch(config.profiles, profile, :unknown_profile),
         true <- capability in @capabilities || {:error, {:unknown_capability, capability}},
         {:ok, slot} <- slot(slots, capability) do
      {:ok, Enum.map([slot.use | slot.fallbacks], &Map.fetch!(config.providers, &1))}
    end
  end

  defp slot(slots, capability) do
    case Map.fetch(slots, capability) do
      {:ok, slot} -> {:ok, slot}
      :error -> {:error, {:capability_not_configured, capability}}
    end
  end

  @doc """
  Runs `fun` against the providers for `capability`, in order, until one succeeds.

  A provider is skipped, without being called, if its API key is not set or its
  rate limit is used up. A provider that returns an error is followed by the next.
  If the budget is spent, nothing is called. Options:

    * `:env` - map of environment variables (default: the real environment)
    * `:usage` - the `Retake.Providers.Usage` server (default: the app's)
    * `:video_id` - the video to charge, for the per-video budget cap
    * `:now` - time in milliseconds (default: now)
  """
  @spec run(Config.t(), String.t(), atom(), (Provider.t(), String.t() | nil -> term()), keyword()) ::
          {:ok, term(),
           %{
             optional(:failed) => [attempt()],
             provider: String.t(),
             usage: map()
           }}
          | {:error, {:budget_exceeded, :video | :day}}
          | {:error, {:all_providers_failed, [attempt()]}}
          | {:error, {:unknown_profile, String.t()} | {:unknown_capability, atom()}}
  def run(%Config{} = config, profile, capability, fun, opts \\ []) do
    context = %{
      env: Keyword.get(opts, :env),
      usage: Keyword.get(opts, :usage, Usage),
      video_id: Keyword.get(opts, :video_id),
      now: Keyword.get_lazy(opts, :now, fn -> System.os_time(:millisecond) end)
    }

    with {:ok, providers} <- resolve(config, profile, capability),
         :ok <- Usage.check_budget(context.usage, config.budget, context.video_id, context.now) do
      try_providers(providers, fun, context, [])
    end
  end

  defp fetch(map, key, error_tag) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {error_tag, key}}
    end
  end

  defp try_providers([], _fun, _context, attempts) do
    {:error, {:all_providers_failed, Enum.reverse(attempts)}}
  end

  defp try_providers([provider | rest], fun, context, attempts) do
    with {:ok, key} <- Provider.api_key(provider, context.env),
         :ok <- Usage.reserve(context.usage, provider.name, provider.rate_limit, context.now),
         {:ok, result, usage} <- fun.(provider, key) do
      :ok =
        Usage.charge(context.usage, context.video_id, Map.get(usage, :cost_usd, 0.0), context.now)

      {:ok, result, answered(provider, usage, attempts)}
    else
      {:error, reason} -> next(rest, fun, context, attempts, provider, reason)
      other -> next(rest, fun, context, attempts, provider, {:invalid_adapter_result, other})
    end
  end

  # `failed`: the providers tried before this one, and why they did not answer. Only present when
  # there were any, because a caller only sees the answer and a fallback would be invisible.
  defp answered(provider, usage, []), do: %{provider: provider.name, usage: usage}

  defp answered(provider, usage, attempts) do
    %{provider: provider.name, usage: usage, failed: Enum.reverse(attempts)}
  end

  defp next(rest, fun, context, attempts, provider, reason) do
    try_providers(rest, fun, context, [%{provider: provider.name, reason: reason} | attempts])
  end
end
