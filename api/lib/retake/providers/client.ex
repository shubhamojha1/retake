defmodule Retake.Providers.Client do
  @moduledoc """
  The one way pipeline steps call a provider (AGENTS.md rules 5 and 9). It joins
  the pieces under it:

    1. resolve the providers for the capability in the profile (`Retake.Providers`),
    2. look in the request cache for each provider in turn (`Retake.Cache`): a hit
       costs nothing and uses no rate limit,
    3. on a miss, call the providers with fallbacks, rate limits and the budget
       (`Retake.Providers.run/5`) through their adapters (`Retake.Providers.Adapters`),
    4. store the answer with its provenance and cost.

  `:validate` (a function of the output returning `:ok` or `{:error, reason}`) runs on
  every fresh answer before it is stored. An answer that fails counts as that provider
  failing, so the next provider is tried, and it is never cached: a bad LLM reply must
  not be served from the cache on every retry.

  A client is cheap; make one per video run.
  """

  alias Retake.Cache
  alias Retake.Providers
  alias Retake.Providers.{Adapters, Config, Provider, Usage}
  alias Retake.Storage

  @enforce_keys [:config, :profile, :storage, :cache_root]
  defstruct [
    :config,
    :profile,
    :storage,
    :cache_root,
    env: nil,
    usage: Usage,
    video_id: nil,
    now: nil
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          profile: String.t(),
          storage: Storage.t(),
          cache_root: Path.t(),
          env: %{String.t() => String.t()} | nil,
          usage: GenServer.server(),
          video_id: String.t() | nil,
          now: DateTime.t() | nil
        }

  @doc """
  Options: `:config`, `:profile`, `:storage`, `:cache_root` (required); `:env` (a map of
  environment variables, default the real one); `:usage` (default the app's
  `Retake.Providers.Usage`); `:video_id` (for the per-video budget cap); `:now` (a
  `DateTime`, for tests).
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  A client from a providers file (`config/providers.toml`). The storage and cache
  directories come from its `[storage]` and `[cache]` tables; relative paths are
  relative to the project root, the directory above the file's own (`config/..`).

  Options: `:profile` (default `RETAKE_PROFILE` from `:env`, else the file's default);
  `:env`, `:usage`, `:video_id`, `:now` as in `new/1`.

  Returns `{:error, errors}` for an invalid file, `{:error, {:unknown_profile, name}}`
  or `{:error, {:unsupported_storage_backend, name}}`.
  """
  @spec from_file(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_file(path, opts \\ []) do
    with {:ok, config} <- Config.load(path) do
      root = path |> Path.expand() |> Path.dirname() |> Path.dirname()
      profile = Keyword.get(opts, :profile) || Config.profile_name(config, opts[:env])

      with :ok <- check_profile(config, profile),
           {:ok, storage} <- storage(config, root) do
        extra = Keyword.take(opts, [:env, :usage, :video_id, :now])

        {:ok,
         new(
           [
             config: config,
             profile: profile,
             storage: storage,
             cache_root: Path.expand(config.cache["root"] || "./.retake/cache", root)
           ] ++ extra
         )}
      end
    end
  end

  defp check_profile(config, profile) do
    if Map.has_key?(config.profiles, profile),
      do: :ok,
      else: {:error, {:unknown_profile, profile}}
  end

  defp storage(config, root) do
    case config.storage["backend"] || "local" do
      "local" ->
        {:ok,
         Retake.Storage.Local.new(Path.expand(config.storage["root"] || "./.retake/store", root))}

      other ->
        {:error, {:unsupported_storage_backend, other}}
    end
  end

  @doc """
  Makes `request` to the providers for `capability`. Returns `{:ok, entry, :hit | :miss}`
  (`entry.result` is `{:json, term}` or `{:asset, ref}`) or `{:error, reason}`.

  Options: `:force` (skip the cache), `:validate` (see the module doc).
  """
  @spec call(t(), atom(), map(), keyword()) ::
          {:ok, Cache.Entry.t(), :hit | :miss} | {:error, term()}
  def call(%__MODULE__{} = client, capability, request, opts \\ []) do
    with {:ok, providers} <- Providers.resolve(client.config, client.profile, capability) do
      parts = fn provider -> parts(provider, capability, request) end

      with false <- Keyword.get(opts, :force, false),
           {:ok, entry} <- cached(client, providers, parts) do
        {:ok, entry, :hit}
      else
        _miss -> fresh(client, providers, capability, parts, request, opts)
      end
    end
  end

  # The first provider, in order, that already has an answer for this request.
  defp cached(client, providers, parts) do
    Enum.find_value(providers, :miss, fn provider ->
      case Cache.lookup(client.cache_root, client.storage, parts.(provider)) do
        {:ok, entry} -> {:ok, entry}
        :miss -> nil
      end
    end)
  end

  defp fresh(client, providers, capability, parts, request, opts) do
    {now, now_ms} = clock(client)

    run_opts = [env: client.env, usage: client.usage, video_id: client.video_id, now: now_ms]
    call_adapter = fn provider, key -> call_adapter(provider, key, request, opts[:validate]) end

    with {:ok, output, %{provider: name, usage: usage}} <-
           Providers.run(client.config, client.profile, capability, call_adapter, run_opts),
         provider = Enum.find(providers, &(&1.name == name)),
         {:ok, entry} <-
           Cache.store(
             client.cache_root,
             client.storage,
             parts.(provider),
             output,
             meta(usage),
             now
           ) do
      {:ok, entry, :miss}
    end
  end

  defp call_adapter(%Provider{} = provider, key, request, validate) do
    case Adapters.fetch(provider.adapter) do
      :error ->
        {:error, {:unknown_adapter, provider.adapter}}

      {:ok, adapter} ->
        with {:ok, output, usage} <- adapter.call(provider, key, effective(provider, request)),
             :ok <- validate_output(validate, output) do
          {:ok, output, usage}
        end
    end
  end

  defp validate_output(nil, _output), do: :ok

  defp validate_output(validate, output) do
    case validate.(output) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_result, reason}}
    end
  end

  # The request as this provider will actually receive it: its adapter may fill in defaults
  # from the provider's settings (`Retake.Providers.Adapter.normalize_request/2`).
  defp effective(provider, request) do
    with {:ok, adapter} <- Adapters.fetch(provider.adapter),
         true <-
           Code.ensure_loaded?(adapter) and function_exported?(adapter, :normalize_request, 2) do
      adapter.normalize_request(provider, request)
    else
      _ -> request
    end
  end

  defp parts(provider, capability, request) do
    %{
      capability: capability,
      provider: provider.name,
      model: to_string(provider.options["model"] || ""),
      request: effective(provider, request)
    }
  end

  # ponytail: an answer that fails validation is not charged to the budget; charge it
  # (it cost tokens) if a paid provider makes that matter.
  defp meta(usage) do
    %{
      cost: %{
        amount: Map.get(usage, :cost_usd, 0.0),
        currency: "USD",
        units: Map.get(usage, :units, %{})
      }
    }
  end

  defp clock(%__MODULE__{now: nil}) do
    now = DateTime.utc_now()
    {now, DateTime.to_unix(now, :millisecond)}
  end

  defp clock(%__MODULE__{now: now}), do: {now, DateTime.to_unix(now, :millisecond)}
end
