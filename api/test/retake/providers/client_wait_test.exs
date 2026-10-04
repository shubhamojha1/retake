defmodule Retake.Providers.ClientWaitTest do
  @moduledoc "A call that hits a short rate limit waits for it to clear instead of failing."

  use ExUnit.Case, async: true

  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @toml """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "a", fallbacks = ["b"] }
  tts = { use = "x", fallbacks = [] }
  stt = { use = "x", fallbacks = [] }
  stock = { use = "x", fallbacks = [] }
  music = { use = "x", fallbacks = [] }

  [providers.a]
  capability = "llm"
  adapter = "fake"
  api_key_env = "A_KEY"
  rate_limit = { requests_per_minute = 1 }

  [providers.b]
  capability = "llm"
  adapter = "fake"
  api_key_env = "B_KEY"

  [providers.x]
  capability = "any"
  adapter = "fake"
  """

  defp request(n), do: %{"messages" => [%{"role" => "user", "content" => "request #{n}"}]}

  # A clock the test controls: the client reads it, and "sleeping" moves it forward.
  defp client(dir, opts) do
    {:ok, config} = Config.parse(@toml)
    Process.put(:clock, ~U[2026-10-04 12:00:00Z])

    sleep = fn ms ->
      send(self(), {:slept, ms})
      Process.put(:clock, DateTime.add(Process.get(:clock), ms, :millisecond))
    end

    Client.new(
      Keyword.merge(
        [
          config: config,
          profile: "dev",
          storage: Local.new(Path.join(dir, "store")),
          cache_root: Path.join(dir, "cache"),
          env: %{"A_KEY" => "key-a"},
          usage: start_supervised!(Usage, id: make_ref()),
          now: fn -> Process.get(:clock) end,
          sleep: sleep
        ],
        opts
      )
    )
  end

  defp answers(map), do: Process.put(:fake_adapter_answers, map)
  defp ok(value), do: {:ok, {:json, value}, %{}}

  test "waits for the rate limit to clear, then succeeds", %{tmp_dir: dir} do
    client = client(dir, max_wait_ms: 120_000)
    answers(%{"a" => ok("answer")})

    assert {:ok, _, :miss} = Client.call(client, :llm, request(1))
    refute_received {:slept, _}

    # "a" allows one call a minute and has just had one: the next waits the minute out
    assert {:ok, entry, :miss} = Client.call(client, :llm, request(2))
    assert entry.provider == "a"
    assert_received {:slept, 60_025}
    refute_received {:slept, _}
  end

  test "does not wait by default", %{tmp_dir: dir} do
    client = client(dir, [])
    answers(%{"a" => ok("answer")})
    {:ok, _, :miss} = Client.call(client, :llm, request(1))

    assert {:error, {:all_providers_failed, attempts}} = Client.call(client, :llm, request(2))
    assert Enum.any?(attempts, &match?(%{reason: {:rate_limited, :minute, _}}, &1))
    refute_received {:slept, _}
  end

  test "gives up when the wait would exceed the budget", %{tmp_dir: dir} do
    client = client(dir, max_wait_ms: 30_000)
    answers(%{"a" => ok("answer")})
    {:ok, _, :miss} = Client.call(client, :llm, request(1))

    assert {:error, {:all_providers_failed, _}} = Client.call(client, :llm, request(2))
    refute_received {:slept, _}
  end

  test "a failure that is not a rate limit is not waited for", %{tmp_dir: dir} do
    client = client(dir, max_wait_ms: 120_000)
    answers(%{"a" => {:error, {:transport, :econnrefused}}})

    assert {:error,
            {:all_providers_failed,
             [%{reason: {:transport, :econnrefused}}, %{reason: {:missing_env, "B_KEY"}}]}} =
             Client.call(client, :llm, request(1))

    refute_received {:slept, _}
  end

  test "a rate limit among other failures is still waited for", %{tmp_dir: dir} do
    client = client(dir, max_wait_ms: 120_000)
    answers(%{"a" => ok("answer")})
    {:ok, _, :miss} = Client.call(client, :llm, request(1))

    # "b" has no key, "a" is rate limited: "a" will recover
    assert {:ok, %{provider: "a"}, :miss} = Client.call(client, :llm, request(2))
    assert_received {:slept, 60_025}
  end

  test "a cache hit never waits", %{tmp_dir: dir} do
    client = client(dir, max_wait_ms: 120_000)
    answers(%{"a" => ok("answer")})
    {:ok, _, :miss} = Client.call(client, :llm, request(1))

    assert {:ok, _, :hit} = Client.call(client, :llm, request(1))
    refute_received {:slept, _}
  end

  test "waits when the budget only just covers the wait", %{tmp_dir: dir} do
    client = client(dir, max_wait_ms: 60_030)
    answers(%{"a" => ok("answer")})
    {:ok, _, :miss} = Client.call(client, :llm, request(1))

    assert {:ok, _, :miss} = Client.call(client, :llm, request(2))
    assert_received {:slept, 60_025}
  end
end
