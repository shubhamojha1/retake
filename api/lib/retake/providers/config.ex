defmodule Retake.Providers.Config do
  @moduledoc """
  Loads and validates `config/providers.toml` (see `config/providers.example.toml`).

  Capabilities are jobs (llm, tts, stt, stock, music, and optionally image). A provider is one way of
  doing a job. A profile picks one provider per capability, plus fallbacks.
  Errors are `%{path, message}` with the TOML path of the problem, and every
  problem is reported, not just the first.
  """

  alias Retake.Providers.Provider

  @capability_list [llm: "llm", tts: "tts", stt: "stt", stock: "stock", music: "music"]
  # Not every profile needs these: without a slot the pipeline does without (no `image` slot
  # means stock only).
  @optional_capability_list [image: "image"]
  @provider_capabilities Map.new(
                           @capability_list ++ @optional_capability_list,
                           fn {atom, name} -> {name, atom} end
                         )
                         |> Map.put("any", :any)
  @rate_windows %{
    "requests_per_minute" => :requests_per_minute,
    "requests_per_hour" => :requests_per_hour,
    "requests_per_day" => :requests_per_day,
    "requests_per_month" => :requests_per_month
  }
  @budget_keys %{
    "max_cost_per_video_usd" => :max_cost_per_video_usd,
    "max_cost_per_day_usd" => :max_cost_per_day_usd
  }
  @provider_keys ~w(capability adapter api_key_env rate_limit)

  defstruct [
    :default_profile,
    budget: %{},
    profiles: %{},
    providers: %{},
    storage: %{},
    cache: %{}
  ]

  @type slot :: %{use: String.t(), fallbacks: [String.t()]}
  @type error :: %{path: String.t(), message: String.t()}
  @type t :: %__MODULE__{
          default_profile: String.t(),
          budget: %{atom() => float()},
          profiles: %{String.t() => %{atom() => slot()}},
          providers: %{String.t() => Provider.t()},
          storage: map(),
          cache: map()
        }

  @doc "Reads and validates a providers TOML file."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [error()]}
  def load(path) do
    case File.read(path) do
      {:ok, body} ->
        parse(body)

      {:error, reason} ->
        {:error, [error("", "cannot read #{path}: #{:file.format_error(reason)}")]}
    end
  end

  @doc "Parses and validates providers TOML text."
  @spec parse(String.t()) :: {:ok, t()} | {:error, [error()]}
  def parse(toml) do
    case TomlElixir.decode(toml, spec: :"1.0.0") do
      {:ok, raw} -> build(raw)
      {:error, e} -> {:error, [error("", "invalid TOML: " <> Exception.message(e))]}
    end
  end

  @doc """
  The profile to use: `RETAKE_PROFILE` from `env` (a map; `nil` means the real
  environment) if set and not blank, otherwise the configured default.
  """
  @spec profile_name(t(), %{String.t() => String.t()} | nil) :: String.t()
  def profile_name(%__MODULE__{default_profile: default}, env \\ nil) do
    case Provider.get_env(env, "RETAKE_PROFILE") do
      value when is_binary(value) ->
        if String.trim(value) == "", do: default, else: String.trim(value)

      _ ->
        default
    end
  end

  # --- building ----------------------------------------------------------------

  defp build(raw) do
    {providers, provider_errors} = parse_providers(table(raw, "providers"))
    {profiles, profile_errors} = parse_profiles(table(raw, "profiles"), providers)
    {budget, budget_errors} = parse_budget(table(raw, "budget"))
    {default, default_errors} = parse_default_profile(table(raw, "retake"), profiles)

    case provider_errors ++ profile_errors ++ budget_errors ++ default_errors do
      [] ->
        {:ok,
         %__MODULE__{
           default_profile: default,
           budget: budget,
           profiles: profiles,
           providers: providers,
           storage: table(raw, "storage"),
           cache: table(raw, "cache")
         }}

      errors ->
        {:error, errors}
    end
  end

  defp table(raw, key) do
    case Map.get(raw, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp error(path, message), do: %{path: path, message: message}

  # --- providers ---------------------------------------------------------------

  defp parse_providers(table) do
    Enum.reduce(table, {%{}, []}, fn {name, attrs}, {providers, errors} ->
      case parse_provider(name, attrs) do
        {:ok, provider} -> {Map.put(providers, name, provider), errors}
        {:error, new_errors} -> {providers, errors ++ new_errors}
      end
    end)
  end

  defp parse_provider(name, attrs) when is_map(attrs) do
    path = "providers.#{name}"
    {capability, capability_errors} = parse_capability(attrs["capability"], path)
    {rate_limit, rate_errors} = parse_rate_limit(attrs["rate_limit"], path <> ".rate_limit")

    errors =
      literal_key_errors(attrs, path) ++
        capability_errors ++
        string_errors(attrs["adapter"], path <> ".adapter", required: true) ++
        string_errors(attrs["api_key_env"], path <> ".api_key_env", required: false) ++
        rate_errors

    case errors do
      [] ->
        {:ok,
         %Provider{
           name: name,
           capability: capability,
           adapter: attrs["adapter"],
           api_key_env: attrs["api_key_env"],
           rate_limit: rate_limit,
           options: Map.drop(attrs, @provider_keys)
         }}

      _ ->
        {:error, errors}
    end
  end

  defp parse_provider(name, _other), do: {:error, [error("providers.#{name}", "must be a table")]}

  # Rule 7: keys come only from the environment, never from this file.
  defp literal_key_errors(attrs, path) do
    if Map.has_key?(attrs, "api_key") do
      [
        error(
          path <> ".api_key",
          "literal API keys are not allowed in this file; set api_key_env to the name " <>
            "of an environment variable that holds the key"
        )
      ]
    else
      []
    end
  end

  defp parse_capability(value, path) do
    case Map.fetch(@provider_capabilities, value) do
      {:ok, capability} ->
        {capability, []}

      :error ->
        expected = @provider_capabilities |> Map.keys() |> Enum.sort() |> Enum.join(", ")

        {nil,
         [
           error(
             path <> ".capability",
             "unknown capability #{inspect(value)}; expected one of #{expected}"
           )
         ]}
    end
  end

  defp string_errors(value, _path, required: false) when is_nil(value), do: []

  defp string_errors(value, path, _opts) when is_binary(value) do
    if String.trim(value) == "", do: [error(path, "must not be blank")], else: []
  end

  defp string_errors(_value, path, _opts), do: [error(path, "is required and must be a string")]

  defp parse_rate_limit(nil, _path), do: {%{}, []}

  defp parse_rate_limit(limits, path) when is_map(limits) do
    Enum.reduce(limits, {%{}, []}, fn {key, value}, {acc, errors} ->
      case Map.fetch(@rate_windows, key) do
        :error ->
          expected = @rate_windows |> Map.keys() |> Enum.sort() |> Enum.join(", ")

          {acc,
           errors ++
             [
               error(
                 "#{path}.#{key}",
                 "unknown rate limit #{inspect(key)}; expected one of #{expected}"
               )
             ]}

        {:ok, atom} when is_integer(value) and value > 0 ->
          {Map.put(acc, atom, value), errors}

        {:ok, _atom} ->
          {acc, errors ++ [error("#{path}.#{key}", "must be a positive integer")]}
      end
    end)
  end

  defp parse_rate_limit(_other, path), do: {%{}, [error(path, "must be a table")]}

  # --- profiles ----------------------------------------------------------------

  defp parse_profiles(table, providers) do
    Enum.reduce(table, {%{}, []}, fn {name, slots}, {profiles, errors} ->
      {profile, new_errors} = parse_profile(name, slots, providers)
      {Map.put(profiles, name, profile), errors ++ new_errors}
    end)
  end

  defp parse_profile(name, slots, providers) do
    slots = if is_map(slots), do: slots, else: %{}

    Enum.reduce(@capability_list ++ @optional_capability_list, {%{}, []}, fn {capability,
                                                                              capability_name},
                                                                             {profile, errors} ->
      path = "profiles.#{name}.#{capability_name}"
      raw = Map.get(slots, capability_name)

      if is_nil(raw) and Keyword.has_key?(@optional_capability_list, capability) do
        {profile, errors}
      else
        case parse_slot(raw, capability, path, providers) do
          {:ok, slot} -> {Map.put(profile, capability, slot), errors}
          {:error, new_errors} -> {profile, errors ++ new_errors}
        end
      end
    end)
  end

  defp parse_slot(nil, capability, path, _providers) do
    {:error, [error(path, "capability #{capability} is missing from this profile")]}
  end

  defp parse_slot(%{"use" => use} = slot, capability, path, providers) do
    fallbacks = Map.get(slot, "fallbacks", [])

    fallback_errors =
      if is_list(fallbacks) do
        Enum.flat_map(fallbacks, &check_provider(&1, capability, path <> ".fallbacks", providers))
      else
        [error(path <> ".fallbacks", "must be a list of provider names")]
      end

    case check_provider(use, capability, path <> ".use", providers) ++ fallback_errors do
      [] -> {:ok, %{use: use, fallbacks: fallbacks}}
      errors -> {:error, errors}
    end
  end

  defp parse_slot(_other, _capability, path, _providers) do
    {:error, [error(path, "must be a table with a `use` provider and optional `fallbacks`")]}
  end

  defp check_provider(name, capability, path, providers) do
    case Map.get(providers, name) do
      nil ->
        [error(path, "unknown provider #{inspect(name)}")]

      %Provider{capability: provided} when provided in [capability, :any] ->
        []

      %Provider{capability: provided} ->
        [error(path, "provider #{inspect(name)} is a #{provided} provider, not #{capability}")]
    end
  end

  # --- budget and default profile ------------------------------------------------

  defp parse_budget(table) do
    Enum.reduce(@budget_keys, {%{}, []}, fn {key, atom}, {budget, errors} ->
      case Map.fetch(table, key) do
        :error ->
          {budget, errors}

        {:ok, value} when is_number(value) and value >= 0 ->
          {Map.put(budget, atom, value * 1.0), errors}

        {:ok, value} when is_number(value) ->
          {budget, errors ++ [error("budget.#{key}", "must not be negative")]}

        {:ok, _value} ->
          {budget, errors ++ [error("budget.#{key}", "must be a number")]}
      end
    end)
  end

  defp parse_default_profile(table, profiles) do
    case Map.get(table, "default_profile") do
      nil ->
        {nil, [error("retake.default_profile", "is required")]}

      name when is_map_key(profiles, name) ->
        {name, []}

      name ->
        {nil, [error("retake.default_profile", "unknown profile #{inspect(name)}")]}
    end
  end
end
