defmodule Retake.Providers.ConfigTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Config

  @example Path.expand("../../../../config/providers.example.toml", __DIR__)

  # The smallest valid config: one provider per capability, "a" (key, rate limit) falling back to "b".
  @minimal """
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
  model = "big"
  rate_limit = { requests_per_minute = 2, requests_per_day = 100 }

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

  defp errors({:error, errors}), do: errors

  defp assert_error(result, path, fragment) do
    errors = errors(result)

    assert Enum.any?(errors, &(&1.path == path and &1.message =~ fragment)),
           "expected an error at #{inspect(path)} mentioning #{inspect(fragment)}, got: #{inspect(errors)}"
  end

  describe "the shipped example config" do
    test "loads" do
      assert {:ok, config} = Config.load(@example)
      assert config.default_profile == "free"
      assert Map.keys(config.profiles) |> Enum.sort() == ["dev", "free", "test"]
    end

    test "describes providers with keys from the environment and rate limits" do
      {:ok, config} = Config.load(@example)
      groq = config.providers["groq"]

      assert groq.capability == :llm
      assert groq.adapter == "openai_compatible"
      assert groq.api_key_env == "GROQ_API_KEY"
      assert groq.rate_limit == %{requests_per_minute: 25, requests_per_day: 900}
      assert groq.options["model"] =~ "gpt-oss"
    end

    test "profiles name a primary and fallbacks per capability" do
      {:ok, config} = Config.load(@example)
      assert config.profiles["free"].llm == %{use: "groq", fallbacks: ["ollama"]}
      assert config.profiles["test"].llm == %{use: "recorded", fallbacks: []}
    end

    test "has budget caps" do
      {:ok, config} = Config.load(@example)
      assert config.budget == %{max_cost_per_video_usd: 0.5, max_cost_per_day_usd: 2.0}
    end

    test "the free profile makes images with Cloudflare; dev and test have no image slot" do
      {:ok, config} = Config.load(@example)

      # portrait pictures first; the square FLUX.1 model is the fallback
      assert config.profiles["free"].image == %{
               use: "cloudflare-flux2",
               fallbacks: ["cloudflare-flux"]
             }

      flux2 = config.providers["cloudflare-flux2"]
      assert flux2.capability == :image
      assert flux2.adapter == "cloudflare_workers_ai_image"
      assert flux2.options["model"] == "@cf/black-forest-labs/flux-2-klein-4b"
      assert flux2.options["width"] == 1080
      assert flux2.options["height"] == 1920
      assert flux2.rate_limit == %{requests_per_day: 30}
      # klein queues parallel calls and times out; one at a time is faster (measured)
      assert flux2.options["one_at_a_time"] == true
      assert flux2.options["timeout_ms"] == 120_000

      refute Map.has_key?(config.profiles["dev"], :image)
      refute Map.has_key?(config.profiles["test"], :image)

      flux = config.providers["cloudflare-flux"]
      assert flux.capability == :image
      assert flux.adapter == "cloudflare_workers_ai_image"
      assert flux.api_key_env == "CLOUDFLARE_API_TOKEN"
      assert flux.options["account_id_env"] == "CLOUDFLARE_ACCOUNT_ID"
      assert flux.options["model"] == "@cf/black-forest-labs/flux-1-schnell"
      assert flux.rate_limit == %{requests_per_day: 150}
    end
  end

  describe "load/1 and parse/1" do
    test "a missing file is an error, not a crash" do
      assert {:error, [%{path: "", message: message}]} = Config.load("no/such/providers.toml")
      assert message =~ "no/such/providers.toml"
    end

    test "invalid TOML is an error" do
      assert {:error, [%{path: ""}]} = Config.parse("this is = = not toml")
    end

    test "the minimal config parses" do
      assert {:ok, config} = Config.parse(@minimal)
      assert config.providers["a"].rate_limit == %{requests_per_minute: 2, requests_per_day: 100}
      assert config.providers["b"].rate_limit == %{}
      assert config.providers["b"].api_key_env == nil
    end
  end

  describe "validation" do
    test "default_profile must exist" do
      result =
        Config.parse(
          String.replace(@minimal, ~s(default_profile = "dev"), ~s(default_profile = "nope"))
        )

      assert_error(result, "retake.default_profile", "nope")
    end

    test "a profile must cover every capability" do
      result =
        Config.parse(String.replace(@minimal, ~s(music = { use = "m", fallbacks = [] }\n), ""))

      assert_error(result, "profiles.dev.music", "missing")
    end

    test "the image capability is optional in a profile" do
      assert {:ok, config} = Config.parse(@minimal)
      refute Map.has_key?(config.profiles["dev"], :image)
    end

    test "a profile may use an image provider" do
      toml =
        @minimal
        |> String.replace(
          ~s(music = { use = "m", fallbacks = [] }\n),
          ~s(music = { use = "m", fallbacks = [] }\nimage = { use = "i", fallbacks = [] }\n)
        )
        |> Kernel.<>("""

        [providers.i]
        capability = "image"
        adapter = "cloudflare_workers_ai_image"
        """)

      assert {:ok, config} = Config.parse(toml)
      assert config.profiles["dev"].image == %{use: "i", fallbacks: []}
      assert config.providers["i"].capability == :image
    end

    test "an image slot must name an image provider" do
      toml =
        String.replace(
          @minimal,
          ~s(music = { use = "m", fallbacks = [] }\n),
          ~s(music = { use = "m", fallbacks = [] }\nimage = { use = "k", fallbacks = [] }\n)
        )

      assert_error(Config.parse(toml), "profiles.dev.image.use", "stock")
    end

    test "a profile cannot use an unknown provider" do
      result = Config.parse(String.replace(@minimal, ~s(use = "t"), ~s(use = "ghost")))
      assert_error(result, "profiles.dev.tts.use", "ghost")
    end

    test "a fallback cannot be an unknown provider" do
      result =
        Config.parse(String.replace(@minimal, ~s(fallbacks = ["b"]), ~s(fallbacks = ["ghost"])))

      assert_error(result, "profiles.dev.llm.fallbacks", "ghost")
    end

    test "a provider can only fill its own capability" do
      # "t" is a tts provider, not an llm
      result =
        Config.parse(String.replace(@minimal, ~s(fallbacks = ["b"]), ~s(fallbacks = ["t"])))

      assert_error(result, "profiles.dev.llm.fallbacks", "tts")
    end

    test "capability any fits every slot" do
      toml = String.replace(@minimal, ~s(capability = "music"), ~s(capability = "any"))
      assert {:ok, _} = Config.parse(toml)
    end

    test "an unknown capability is rejected" do
      result =
        Config.parse(String.replace(@minimal, ~s(capability = "music"), ~s(capability = "smell")))

      assert_error(result, "providers.m.capability", "smell")
    end

    test "a literal API key is rejected: keys come from the environment" do
      toml = String.replace(@minimal, ~s(api_key_env = "A_KEY"), ~s(api_key = "sk-live-123"))
      result = Config.parse(toml)
      assert_error(result, "providers.a.api_key", "api_key_env")
      refute inspect(errors(result)) =~ "sk-live-123"
    end

    test "an unknown rate limit key is rejected" do
      toml = String.replace(@minimal, "requests_per_day = 100", "requests_per_decade = 1")
      assert_error(Config.parse(toml), "providers.a.rate_limit.requests_per_decade", "unknown")
    end

    test "rate limits must be positive integers" do
      toml = String.replace(@minimal, "requests_per_minute = 2", "requests_per_minute = 0")
      assert_error(Config.parse(toml), "providers.a.rate_limit.requests_per_minute", "positive")
    end

    test "budget caps cannot be negative" do
      toml = String.replace(@minimal, "max_cost_per_day_usd = 2.0", "max_cost_per_day_usd = -1")
      assert_error(Config.parse(toml), "budget.max_cost_per_day_usd", "negative")
    end

    test "reports every problem, not just the first" do
      toml =
        @minimal
        |> String.replace(~s(use = "t"), ~s(use = "ghost"))
        |> String.replace(~s(default_profile = "dev"), ~s(default_profile = "nope"))

      errors = errors(Config.parse(toml))
      assert length(errors) >= 2
    end
  end

  describe "profile_name/2" do
    setup do
      {:ok, config} = Config.parse(@minimal)
      %{config: config}
    end

    test "defaults to the configured default profile", %{config: config} do
      assert Config.profile_name(config, %{}) == "dev"
    end

    test "RETAKE_PROFILE in the environment overrides it", %{config: config} do
      assert Config.profile_name(config, %{"RETAKE_PROFILE" => "free"}) == "free"
    end

    test "a blank RETAKE_PROFILE is ignored", %{config: config} do
      assert Config.profile_name(config, %{"RETAKE_PROFILE" => ""}) == "dev"
    end
  end
end
