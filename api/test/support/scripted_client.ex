defmodule Retake.Test.ScriptedClient do
  @moduledoc """
  A provider client wired to the scripted stand-ins (`Retake.Test.ScriptedAdapter`), for tests
  that run the whole pipeline offline: a canned script, fixture footage, silent narration.

  `overrides` adds lines to one provider's block of the TOML, by provider name (`"llm"`,
  `"voice"`, `"ears"`, `"stock"`): `%{"llm" => "fail = true"}` makes that provider fail.
  `usage` is the rate-limit server (`start_supervised!(Retake.Providers.Usage, id: make_ref())`).
  """

  alias Retake.Providers.{Client, Config}
  alias Retake.Storage.Local

  @spec client(Path.t(), pid(), map()) :: Client.t()
  def client(dir, usage, overrides \\ %{}) do
    {:ok, config} = Config.parse(toml(dir, overrides))

    Client.new(
      config: config,
      profile: "test",
      storage: Local.new(Path.join(dir, "store")),
      cache_root: Path.join(dir, "cache"),
      usage: usage
    )
  end

  defp toml(dir, overrides) do
    log = Path.join(dir, "calls.log")
    extra = fn name -> Map.get(overrides, name, "") end

    """
    [retake]
    default_profile = "test"

    [profiles.test]
    llm = { use = "llm", fallbacks = [] }
    tts = { use = "voice", fallbacks = [] }
    stt = { use = "ears", fallbacks = [] }
    stock = { use = "stock", fallbacks = [] }
    music = { use = "llm", fallbacks = [] }

    [providers.llm]
    capability = "any"
    adapter = "scripted"
    role = "llm"
    log = "#{log}"
    #{extra.("llm")}

    [providers.voice]
    capability = "tts"
    adapter = "scripted"
    role = "tts"
    log = "#{log}"
    #{extra.("voice")}

    [providers.ears]
    capability = "stt"
    adapter = "scripted"
    role = "stt"
    log = "#{log}"
    #{extra.("ears")}

    [providers.stock]
    capability = "stock"
    adapter = "scripted"
    role = "stock"
    log = "#{log}"
    #{extra.("stock")}
    """
  end
end
