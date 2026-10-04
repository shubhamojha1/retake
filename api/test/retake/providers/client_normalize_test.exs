defmodule Retake.Providers.ClientNormalizeTest do
  @moduledoc "An adapter fills in request defaults from the provider's settings; the cache key follows."

  use ExUnit.Case, async: true

  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  defp toml(voice) do
    """
    [retake]
    default_profile = "dev"

    [profiles.dev]
    llm = { use = "l", fallbacks = [] }
    tts = { use = "voice", fallbacks = [] }
    stt = { use = "l", fallbacks = [] }
    stock = { use = "l", fallbacks = [] }
    music = { use = "l", fallbacks = [] }

    [providers.l]
    capability = "any"
    adapter = "fake"

    [providers.voice]
    capability = "tts"
    adapter = "fake"
    model = "m"
    request_defaults = { voice = "#{voice}", speed = 1.0 }
    """
  end

  defp client(dir, voice) do
    {:ok, config} = Config.parse(toml(voice))

    Client.new(
      config: config,
      profile: "dev",
      storage: Local.new(Path.join(dir, "store")),
      cache_root: Path.join(dir, "cache"),
      usage: start_supervised!(Usage, id: make_ref())
    )
  end

  defp answer(output), do: Process.put(:fake_adapter_answers, %{"voice" => {:ok, output, %{}}})

  test "the adapter receives the request with the provider's defaults filled in", %{tmp_dir: dir} do
    answer({:json, 1})
    {:ok, _, :miss} = Client.call(client(dir, "alpha"), :tts, %{"text" => "hi"})

    assert_received {:adapter_called, "voice", _key, request}
    assert request == %{"text" => "hi", "voice" => "alpha", "speed" => 1.0}
  end

  test "what the request says wins over a default", %{tmp_dir: dir} do
    answer({:json, 1})

    {:ok, _, :miss} =
      Client.call(client(dir, "alpha"), :tts, %{"text" => "hi", "voice" => "beta"})

    assert_received {:adapter_called, "voice", _key, %{"voice" => "beta", "speed" => 1.0}}
  end

  test "the entry, and so the asset's provenance, holds the request as sent", %{tmp_dir: dir} do
    answer({:json, 1})
    {:ok, entry, :miss} = Client.call(client(dir, "alpha"), :tts, %{"text" => "hi"})

    assert entry.request == %{"text" => "hi", "voice" => "alpha", "speed" => 1.0}
  end

  test "changing a default is a different request: no stale answer from the old setting", %{
    tmp_dir: dir
  } do
    answer({:json, "made with alpha"})
    assert {:ok, _, :miss} = Client.call(client(dir, "alpha"), :tts, %{"text" => "hi"})
    assert {:ok, _, :hit} = Client.call(client(dir, "alpha"), :tts, %{"text" => "hi"})

    answer({:json, "made with gamma"})
    assert {:ok, entry, :miss} = Client.call(client(dir, "gamma"), :tts, %{"text" => "hi"})
    assert entry.result == {:json, "made with gamma"}
  end
end
