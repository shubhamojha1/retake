defmodule Retake.Pipeline.ImagesTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Images
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage
  alias Retake.Storage.Local
  alias Retake.Test.Images, as: TestImages

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "l", fallbacks = [] }
  tts = { use = "t", fallbacks = [] }
  stt = { use = "s", fallbacks = [] }
  stock = { use = "k", fallbacks = [] }
  music = { use = "m", fallbacks = [] }
  image = { use = "painter", fallbacks = [] }

  [providers.painter]
  capability = "image"
  adapter = "fake"
  model = "flux-test"

  [providers.l]
  capability = "llm"
  adapter = "fake"

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

  @scene %{
    narration: "Your phone is the last thing you see at night.",
    visual_query: "phone bed dark",
    image_prompt: "A dim bedroom at night, a phone glowing on a pillow, vertical shot."
  }

  setup %{tmp_dir: dir} do
    %{client: client(dir, @config), dir: dir}
  end

  defp client(dir, toml) do
    {:ok, config} = Config.parse(toml)

    Client.new(
      config: config,
      profile: "dev",
      storage: Local.new(Path.join(dir, "store")),
      cache_root: Path.join(dir, "cache"),
      usage: start_supervised!(Usage, id: make_ref())
    )
  end

  defp paint(answer) do
    Process.put(:fake_adapter_answers, %{"painter" => answer})
  end

  defp image(bytes), do: {:ok, {:binary, bytes, "jpg"}, %{cost_usd: 0.0, units: %{"steps" => 4}}}

  defp painter_calls do
    receive do
      {:adapter_called, "painter", _key, request} -> [request | painter_calls()]
    after
      0 -> []
    end
  end

  describe "generate/2" do
    test "returns a spec asset for the stored image", %{client: client} do
      bytes = TestImages.jpeg(1080, 1920)
      paint(image(bytes))

      assert {:ok, %{asset: asset, prompt: prompt, warnings: []}} =
               Images.generate(client, @scene)

      assert prompt == @scene.image_prompt
      assert asset["kind"] == "image"
      assert asset["media"] == %{"width" => 1080, "height" => 1920, "mime" => "image/jpeg"}
      assert asset["content_hash"] == Storage.content_hash(bytes)
      assert "store://assets/" <> _ = asset["uri"]
      assert asset["license"] == %{"name" => "AI-generated: flux-test"}
    end

    test "the provenance says generated, by whom, with what request", %{client: client} do
      paint(image(TestImages.jpeg(1080, 1920)))
      {:ok, %{asset: asset}} = Images.generate(client, @scene)

      assert %{
               "source" => "generated",
               "capability" => "image",
               "provider" => "painter",
               "model" => "flux-test",
               "request" => %{"prompt" => "A dim bedroom" <> _},
               "request_hash" => "sha256:" <> _,
               "cost" => %{"amount" => amount, "currency" => "USD"}
             } = asset["provenance"]

      assert amount == 0.0
    end

    test "the bytes are in storage", %{client: client, dir: dir} do
      bytes = TestImages.jpeg(1080, 1920)
      paint(image(bytes))
      {:ok, %{asset: asset}} = Images.generate(client, @scene)

      assert Storage.fetch(Local.new(Path.join(dir, "store")), asset["uri"]) == {:ok, bytes}
    end

    test "warns when the image is not portrait", %{client: client} do
      paint(image(TestImages.jpeg(1024, 1024)))
      assert {:ok, %{warnings: [warning]}} = Images.generate(client, @scene)
      assert warning =~ "1024x1024"
      assert warning =~ "not portrait"
    end

    test "a repeat is answered from the cache: the provider is called once", %{client: client} do
      paint(image(TestImages.jpeg(1080, 1920)))

      {:ok, first} = Images.generate(client, @scene)
      {:ok, second} = Images.generate(client, @scene)

      assert first.asset == second.asset
      assert [%{"prompt" => _}] = painter_calls()
    end

    test "a provider failure is returned as the provider layer reports it", %{client: client} do
      paint({:error, {:http, 503, "overloaded"}})

      assert {:error, {:all_providers_failed, [%{provider: "painter", reason: {:http, 503, _}}]}} =
               Images.generate(client, @scene)
    end

    test "a reply that is not an image is an error", %{client: client} do
      paint(image("<html>please log in</html>"))
      assert {:error, {:bad_image, :unknown_format}} = Images.generate(client, @scene)
    end

    test "a profile with no image slot", %{dir: dir} do
      toml = String.replace(@config, ~s(image = { use = "painter", fallbacks = [] }\n), "")

      assert {:error, {:capability_not_configured, :image}} =
               Images.generate(client(dir, toml), @scene)
    end
  end
end
