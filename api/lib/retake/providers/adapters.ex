defmodule Retake.Providers.Adapters do
  @moduledoc """
  Maps the `adapter = "..."` names in `config/providers.toml` to modules. The
  built-in adapters are listed here; `config :retake, :adapters, %{"name" => Module}`
  adds or replaces entries (tests register their fakes this way).

  Only `Retake.Providers.Client` uses this; pipeline code must not (the boundary
  check bans `Retake.Providers.Adapters` in pipeline modules).
  """

  @builtin %{
    "openai_compatible" => Retake.Providers.Adapters.OpenAICompatible,
    "openai_compatible_speech" => Retake.Providers.Adapters.OpenAICompatibleSpeech,
    "pexels" => Retake.Providers.Adapters.Pexels,
    "pixabay" => Retake.Providers.Adapters.Pixabay
  }

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    @builtin
    |> Map.merge(Application.get_env(:retake, :adapters, %{}))
    |> Map.fetch(name)
  end
end
