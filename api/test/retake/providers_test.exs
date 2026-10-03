defmodule Retake.ProvidersTest do
  use ExUnit.Case, async: true

  alias Retake.Providers
  alias Retake.Providers.{Config, Usage}

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
  adapter = "openai_compatible"
  api_key_env = "A_KEY"
  rate_limit = { requests_per_minute = 2 }

  [providers.b]
  capability = "llm"
  adapter = "openai_compatible"

  [providers.t]
  capability = "tts"
  adapter = "openai_compatible_speech"

  [providers.s]
  capability = "stt"
  adapter = "openai_compatible_transcription"

  [providers.k]
  capability = "stock"
  adapter = "local_directory"

  [providers.m]
  capability = "music"
  adapter = "local_library"
  """

  @env %{"A_KEY" => "secret-a"}

  setup do
    {:ok, config} = Config.parse(@config)
    %{config: config, usage: start_supervised!(Usage)}
  end

  # An adapter stand-in: reports every call to the test process, then answers by provider name.
  defp adapter(answers) do
    test = self()

    fn provider, key ->
      send(test, {:called, provider.name, key})
      Map.fetch!(answers, provider.name)
    end
  end

  defp run(config, usage, fun, opts \\ []) do
    opts = Keyword.merge([env: @env, usage: usage, now: 0], opts)
    Providers.run(config, "dev", :llm, fun, opts)
  end

  describe "resolve/3" do
    test "lists the primary first, then the fallbacks", %{config: config} do
      assert {:ok, providers} = Providers.resolve(config, "dev", :llm)
      assert Enum.map(providers, & &1.name) == ["a", "b"]
    end

    test "unknown profile", %{config: config} do
      assert Providers.resolve(config, "nope", :llm) == {:error, {:unknown_profile, "nope"}}
    end

    test "unknown capability", %{config: config} do
      assert Providers.resolve(config, "dev", :smell) == {:error, {:unknown_capability, :smell}}
    end
  end

  describe "run/5" do
    test "uses the primary provider and returns who answered and what it cost", %{
      config: config,
      usage: usage
    } do
      fun = adapter(%{"a" => {:ok, :answer, %{cost_usd: 0.0}}})

      assert run(config, usage, fun) ==
               {:ok, :answer, %{provider: "a", usage: %{cost_usd: 0.0}}}

      assert_received {:called, "a", "secret-a"}
      refute_received {:called, "b", _}
    end

    test "falls back when the primary fails", %{config: config, usage: usage} do
      fun = adapter(%{"a" => {:error, :timeout}, "b" => {:ok, :from_b, %{cost_usd: 0.0}}})

      assert {:ok, :from_b, %{provider: "b"}} = run(config, usage, fun)
      assert_received {:called, "a", _}
      assert_received {:called, "b", nil}
    end

    test "skips a provider whose key is missing without calling it", %{
      config: config,
      usage: usage
    } do
      fun = adapter(%{"b" => {:ok, :from_b, %{cost_usd: 0.0}}})

      assert {:ok, :from_b, %{provider: "b"}} = run(config, usage, fun, env: %{})
      refute_received {:called, "a", _}
    end

    test "when every provider fails, says why for each", %{config: config, usage: usage} do
      fun = adapter(%{"b" => {:error, :boom}})

      assert run(config, usage, fun, env: %{}) ==
               {:error,
                {:all_providers_failed,
                 [
                   %{provider: "a", reason: {:missing_env, "A_KEY"}},
                   %{provider: "b", reason: :boom}
                 ]}}
    end

    test "never puts the key in the failure report", %{config: config, usage: usage} do
      fun = adapter(%{"a" => {:error, :boom}, "b" => {:error, :boom}})
      result = run(config, usage, fun)
      refute inspect(result) =~ "secret-a"
    end

    test "skips a rate-limited provider and uses the next", %{config: config, usage: usage} do
      fun =
        adapter(%{
          "a" => {:ok, :from_a, %{cost_usd: 0.0}},
          "b" => {:ok, :from_b, %{cost_usd: 0.0}}
        })

      assert {:ok, :from_a, _} = run(config, usage, fun, now: 0)
      assert {:ok, :from_a, _} = run(config, usage, fun, now: 1_000)
      # "a" allows 2 calls a minute
      assert {:ok, :from_b, %{provider: "b"}} = run(config, usage, fun, now: 2_000)
    end

    test "a rate-limited provider is usable again once the window passes", %{
      config: config,
      usage: usage
    } do
      fun =
        adapter(%{
          "a" => {:ok, :from_a, %{cost_usd: 0.0}},
          "b" => {:ok, :from_b, %{cost_usd: 0.0}}
        })

      for now <- [0, 1_000], do: run(config, usage, fun, now: now)

      assert {:ok, :from_b, _} = run(config, usage, fun, now: 30_000)
      assert {:ok, :from_a, _} = run(config, usage, fun, now: 61_000)
    end

    test "reports the rate limit when it is the only reason", %{config: config, usage: usage} do
      fun = adapter(%{"a" => {:ok, :from_a, %{cost_usd: 0.0}}, "b" => {:error, :boom}})
      for now <- [0, 1_000], do: run(config, usage, fun, now: now)

      assert {:error,
              {:all_providers_failed, [%{provider: "a", reason: reason}, %{provider: "b"}]}} =
               run(config, usage, fun, now: 2_000)

      assert {:rate_limited, :minute, 58_000} = reason
    end

    test "charges the reported cost, then stops at the per-video cap", %{
      config: config,
      usage: usage
    } do
      fun = adapter(%{"a" => {:ok, :answer, %{cost_usd: 0.3}}})
      opts = [video_id: "v1"]

      assert {:ok, :answer, _} = run(config, usage, fun, opts)
      assert {:ok, :answer, _} = run(config, usage, fun, opts)
      # 0.6 spent, cap 0.5
      assert run(config, usage, fun, opts) == {:error, {:budget_exceeded, :video}}
    end

    test "does not call any provider once the budget is spent", %{config: config, usage: usage} do
      :ok = Usage.charge(usage, "v1", 0.6, 0)
      fun = adapter(%{"a" => {:ok, :answer, %{cost_usd: 0.0}}})

      assert run(config, usage, fun, video_id: "v1") == {:error, {:budget_exceeded, :video}}
      refute_received {:called, _, _}
    end

    test "a failed call is charged nothing", %{config: config, usage: usage} do
      fun = adapter(%{"a" => {:error, :boom}, "b" => {:error, :boom}})
      run(config, usage, fun, video_id: "v1")
      assert Usage.check_budget(usage, config.budget, "v1", 1) == :ok
    end

    test "unknown profile is an error", %{config: config, usage: usage} do
      fun = adapter(%{})

      assert Providers.run(config, "nope", :llm, fun, env: @env, usage: usage, now: 0) ==
               {:error, {:unknown_profile, "nope"}}
    end
  end
end
