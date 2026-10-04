defmodule Retake.Providers.ClientTest do
  use ExUnit.Case, async: true

  alias Retake.Cache.Entry
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [budget]
  max_cost_per_video_usd = 0.5
  max_cost_per_day_usd = 2.0

  [profiles.dev]
  llm = { use = "a", fallbacks = ["b"] }
  tts = { use = "t", fallbacks = [] }
  stt = { use = "s", fallbacks = [] }
  stock = { use = "k", fallbacks = [] }
  music = { use = "m", fallbacks = [] }

  [providers.a]
  capability = "llm"
  adapter = "fake"
  api_key_env = "A_KEY"
  model = "big"
  rate_limit = { requests_per_minute = 2 }

  [providers.b]
  capability = "llm"
  adapter = "fake"
  model = "small"

  [providers.t]
  capability = "tts"
  adapter = "fake"

  [providers.s]
  capability = "stt"
  adapter = "fake"

  [providers.k]
  capability = "stock"
  adapter = "fake"

  [providers.m]
  capability = "music"
  adapter = "fake"
  """

  @request %{"messages" => [%{"role" => "user", "content" => "hello"}]}

  setup %{tmp_dir: dir} do
    {:ok, config} = Config.parse(@config)

    %{
      dir: dir,
      config: config,
      client: fn overrides ->
        Client.new(
          Keyword.merge(
            [
              config: config,
              profile: "dev",
              storage: Local.new(Path.join(dir, "store")),
              cache_root: Path.join(dir, "cache"),
              env: %{"A_KEY" => "secret-a"},
              usage: start_supervised!(Usage, id: make_ref())
            ],
            overrides
          )
        )
      end
    }
  end

  defp answers(map), do: Process.put(:fake_adapter_answers, map)
  defp ok(output, usage \\ %{}), do: {:ok, output, usage}

  describe "call/4" do
    test "a repeated request is answered from the cache without calling the provider", %{
      client: client
    } do
      client = client.([])
      answers(%{"a" => ok({:json, %{"text" => "hi"}})})

      assert {:ok, %Entry{result: {:json, %{"text" => "hi"}}, provider: "a"}, :miss} =
               Client.call(client, :llm, @request)

      assert_received {:adapter_called, "a", "secret-a", @request}

      assert {:ok, %Entry{result: {:json, %{"text" => "hi"}}}, :hit} =
               Client.call(client, :llm, @request)

      refute_received {:adapter_called, _, _, _}
    end

    test "hits do not use up the rate limit", %{client: client} do
      client = client.([])
      answers(%{"a" => ok({:json, 1})})

      # provider "a" allows 2 calls a minute; only the first of these is a call
      for _ <- 1..5, do: assert({:ok, _, _} = Client.call(client, :llm, @request))
    end

    test "binary results are stored as assets", %{client: client, dir: dir} do
      client = client.([])
      answers(%{"a" => ok({:binary, "pixels", "jpg"})})

      assert {:ok, %Entry{result: {:asset, ref}}, :miss} = Client.call(client, :llm, @request)
      assert Storage.fetch(Local.new(Path.join(dir, "store")), ref.uri) == {:ok, "pixels"}
    end

    test "records the model, request and the cost the adapter reported", %{client: client} do
      client = client.([])
      answers(%{"a" => ok({:json, 1}, %{cost_usd: 0.02, units: %{"tokens" => 10}})})

      {:ok, entry, :miss} = Client.call(client, :llm, @request)

      assert entry.model == "big"
      assert entry.capability == :llm
      assert entry.request == @request
      assert entry.cost == %{amount: 0.02, currency: "USD", units: %{"tokens" => 10}}
    end

    test "falls back, and the fallback's answer is cached under the fallback", %{client: client} do
      client = client.([])
      answers(%{"a" => {:error, :down}, "b" => ok({:json, "from b"})})

      assert {:ok, %Entry{provider: "b", model: "small"}, :miss} =
               Client.call(client, :llm, @request)

      # "a" recovers, but the answer already cached for "b" is used: no new call, no quota spent
      answers(%{"a" => ok({:json, "from a"}), "b" => {:error, :unused}})
      flush_adapter_calls()

      assert {:ok, %Entry{provider: "b", result: {:json, "from b"}}, :hit} =
               Client.call(client, :llm, @request)

      refute_received {:adapter_called, _, _, _}
    end

    test "a provider with no key is skipped without being called", %{client: client} do
      client = client.(env: %{})
      answers(%{"a" => ok({:json, "from a"}), "b" => ok({:json, "from b"})})

      assert {:ok, %Entry{provider: "b"}, :miss} = Client.call(client, :llm, @request)
      refute_received {:adapter_called, "a", _, _}
    end

    test "when everything fails, says why and caches nothing", %{client: client} do
      client = client.([])
      answers(%{"a" => {:error, :boom}, "b" => {:error, :bang}})

      assert {:error,
              {:all_providers_failed,
               [%{provider: "a", reason: :boom}, %{provider: "b", reason: :bang}]}} =
               Client.call(client, :llm, @request)

      answers(%{"a" => ok({:json, "ok now"})})
      assert {:ok, _, :miss} = Client.call(client, :llm, @request)
    end

    test "never puts the key in an entry or an error", %{client: client, dir: dir} do
      client = client.([])
      answers(%{"a" => {:error, :boom}, "b" => ok({:json, "x"})})
      {:ok, _, :miss} = Client.call(client, :llm, @request)

      for file <- Path.wildcard(Path.join(dir, "cache/*.json")) do
        refute File.read!(file) =~ "secret-a"
      end
    end

    test "an unknown adapter is a failure for that provider, not a crash", %{
      config: config,
      client: client
    } do
      {:ok, config} =
        Config.parse(
          String.replace(
            @config,
            ~s(adapter = "fake"\napi_key_env),
            ~s(adapter = "nope"\napi_key_env)
          )
        )

      client = client.(config: config)
      answers(%{"b" => ok({:json, "from b"})})

      assert {:ok, %Entry{provider: "b"}, :miss} = Client.call(client, :llm, @request)
    end

    test "force: true skips the cache and replaces the entry", %{client: client} do
      client = client.([])
      answers(%{"a" => ok({:json, "old"})})
      {:ok, _, :miss} = Client.call(client, :llm, @request)

      answers(%{"a" => ok({:json, "new"})})

      assert {:ok, %Entry{result: {:json, "new"}}, :miss} =
               Client.call(client, :llm, @request, force: true)

      assert {:ok, %Entry{result: {:json, "new"}}, :hit} = Client.call(client, :llm, @request)
    end
  end

  describe "validate:" do
    test "an invalid result is not cached and counts as that provider failing", %{client: client} do
      client = client.([])
      answers(%{"a" => ok({:json, "bad"}), "b" => ok({:json, "good"})})
      validate = fn {:json, value} -> if value == "good", do: :ok, else: {:error, :not_good} end

      assert {:ok, %Entry{provider: "b", result: {:json, "good"}}, :miss} =
               Client.call(client, :llm, @request, validate: validate)
    end

    test "when every result is invalid, the reasons are reported and nothing is cached", %{
      client: client,
      dir: dir
    } do
      client = client.([])
      answers(%{"a" => ok({:json, "bad"}), "b" => ok({:json, "worse"})})
      validate = fn _ -> {:error, :not_good} end

      assert {:error,
              {:all_providers_failed,
               [
                 %{provider: "a", reason: {:invalid_result, :not_good}},
                 %{provider: "b", reason: {:invalid_result, :not_good}}
               ]}} = Client.call(client, :llm, @request, validate: validate)

      assert Path.wildcard(Path.join(dir, "cache/*.json")) == []
    end
  end

  describe "budget" do
    test "a miss charges its cost; at the cap, new requests are refused but hits are still served",
         %{client: client} do
      client = client.(video_id: "v1")
      answers(%{"a" => ok({:json, 1}, %{cost_usd: 0.3})})

      first = %{"messages" => [%{"role" => "user", "content" => "one"}]}
      second = %{"messages" => [%{"role" => "user", "content" => "two"}]}
      third = %{"messages" => [%{"role" => "user", "content" => "three"}]}

      assert {:ok, _, :miss} = Client.call(client, :llm, first)
      assert {:ok, _, :miss} = Client.call(client, :llm, second)
      # 0.6 spent, cap 0.5 per video
      assert Client.call(client, :llm, third) == {:error, {:budget_exceeded, :video}}
      assert {:ok, _, :hit} = Client.call(client, :llm, first)
    end
  end

  defp flush_adapter_calls do
    receive do
      {:adapter_called, _, _, _} -> flush_adapter_calls()
    after
      0 -> :ok
    end
  end
end
