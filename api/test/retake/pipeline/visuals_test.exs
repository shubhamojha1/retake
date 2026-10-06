defmodule Retake.Pipeline.VisualsTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Visuals
  alias Retake.Providers.{Client, Config, Usage}
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
  stock = { use = "stock", fallbacks = [] }
  music = { use = "m", fallbacks = [] }
  image = { use = "painter", fallbacks = [] }

  [providers.painter]
  capability = "image"
  adapter = "fake"
  model = "flux-test"

  [providers.stock]
  capability = "stock"
  adapter = "fake"

  [providers.l]
  capability = "llm"
  adapter = "fake"

  [providers.t]
  capability = "tts"
  adapter = "fake"

  [providers.s]
  capability = "stt"
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

  # A fake stock service that finds one portrait photo for any query.
  defp stock_answer do
    candidate = %{
      "kind" => "photo",
      "id" => 1,
      "page_url" => "https://stock.test/p/1",
      "creator" => "P. Hotographer",
      "duration_ms" => nil,
      "source" => "Pexels",
      "license" => %{"name" => "Pexels License"},
      "files" => [
        %{
          "url" => "https://cdn.test/p1.jpg",
          "width" => 1080,
          "height" => 1920,
          "mime" => "image/jpeg"
        }
      ]
    }

    fn
      %{"action" => "search", "kind" => "video"} ->
        {:ok, {:json, %{"results" => []}}, %{}}

      %{"action" => "search", "kind" => "photo"} ->
        {:ok, {:json, %{"results" => [candidate]}}, %{}}

      %{"action" => "download"} ->
        {:ok, {:binary, "photo bytes", "jpg"}, %{}}
    end
  end

  defp serve(painter) do
    Process.put(:fake_adapter_answers, %{"painter" => painter, "stock" => stock_answer()})
  end

  defp portrait do
    {:ok, {:binary, TestImages.jpeg(1080, 1920), "jpg"}, %{cost_usd: 0.0, units: %{}}}
  end

  defp called(provider) do
    receive do
      {:adapter_called, ^provider, _key, request} -> [request | called(provider)]
    after
      0 -> []
    end
  end

  describe "find/3 with an image provider and an image_prompt" do
    test "generates the image and does not touch stock", %{client: client} do
      serve(portrait())

      assert {:ok, found} = Visuals.find(client, @scene)

      assert found.source == :generated
      assert found.prompt == @scene.image_prompt
      assert found.query == "phone bed dark"
      assert found.warnings == []
      assert found.asset["kind"] == "image"
      assert found.asset["provenance"]["source"] == "generated"
      assert called("stock") == []
    end

    test "keeps the image's own warnings (a square image)", %{client: client} do
      serve({:ok, {:binary, TestImages.jpeg(1024, 1024), "jpg"}, %{}})
      assert {:ok, %{source: :generated, warnings: [warning]}} = Visuals.find(client, @scene)
      assert warning =~ "not portrait"
    end
  end

  describe "find/3 falls back to stock" do
    test "when the scene has no image_prompt", %{client: client} do
      serve(portrait())

      assert {:ok, found} = Visuals.find(client, Map.delete(@scene, :image_prompt))

      assert found.source == :stock
      assert found.prompt == nil
      assert found.warnings == []
      assert found.asset["provenance"]["source"] == "stock"
      assert called("painter") == []
    end

    test "when the image_prompt is nil or blank", %{client: client} do
      serve(portrait())

      for blank <- [nil, "", "   "] do
        assert {:ok, %{source: :stock}} = Visuals.find(client, %{@scene | image_prompt: blank})
      end

      assert called("painter") == []
    end

    test "when the profile has no image slot, with no warning", %{dir: dir} do
      toml = String.replace(@config, ~s(image = { use = "painter", fallbacks = [] }\n), "")
      serve(portrait())

      assert {:ok, %{source: :stock, warnings: []}} = Visuals.find(client(dir, toml), @scene)
      assert called("painter") == []
    end

    test "with a warning when the image could not be made", %{client: client} do
      serve({:error, {:http, 503, "overloaded"}})

      assert {:ok, %{source: :stock, prompt: nil, warnings: [warning]}} =
               Visuals.find(client, @scene)

      assert warning =~ "the image could not be made"
      assert warning =~ "overloaded"
      assert warning =~ "stock footage used instead"
      refute warning =~ "\n"
    end

    test "the warning stays short even when the provider's error text is long", %{client: client} do
      serve({:error, {:http, 500, String.duplicate("e", 900)}})

      assert {:ok, %{source: :stock, warnings: [warning]}} = Visuals.find(client, @scene)
      assert String.length(warning) <= 300
      assert warning =~ "stock footage used instead"
    end

    test "with a warning when the image provider returns something that is not an image", %{
      client: client
    } do
      serve({:ok, {:binary, "<html>nope</html>", "jpg"}, %{}})
      assert {:ok, %{source: :stock, warnings: [warning]}} = Visuals.find(client, @scene)
      assert warning =~ "the image could not be made"
    end

    test "with no warning when the image provider has no key", %{dir: dir} do
      toml =
        String.replace(
          @config,
          ~s([providers.painter]\ncapability = "image"),
          ~s([providers.painter]\ncapability = "image"\napi_key_env = "RETAKE_TEST_NO_SUCH_KEY")
        )

      serve(portrait())

      assert {:ok, %{source: :stock, warnings: []}} = Visuals.find(client(dir, toml), @scene)
      assert called("painter") == []
    end
  end

  describe "find/3 when the first image provider did not answer but the second did" do
    test "says so, because the provider layer falls back silently", %{dir: dir} do
      toml =
        @config
        |> String.replace(
          ~s(image = { use = "painter", fallbacks = [] }),
          ~s(image = { use = "painter", fallbacks = ["painter2"] })
        )
        |> Kernel.<>("""

        [providers.painter2]
        capability = "image"
        adapter = "fake"
        model = "flux-square"
        """)

      Process.put(:fake_adapter_answers, %{
        "painter" => {:error, {:transport, :timeout}},
        "painter2" => portrait(),
        "stock" => stock_answer()
      })

      assert {:ok, %{source: :generated, warnings: [warning]}} =
               Visuals.find(client(dir, toml), @scene)

      assert warning =~ "painter"
      assert warning =~ "painter2"
      assert warning =~ "not from the first image provider"
    end

    test "no warning when the first provider made the picture", %{client: client} do
      serve(portrait())
      assert {:ok, %{source: :generated, warnings: []}} = Visuals.find(client, @scene)
    end
  end

  describe "find/3 when stock fails too" do
    test "returns the stock error, not the image error", %{client: client} do
      Process.put(:fake_adapter_answers, %{
        "painter" => {:error, {:http, 503, "overloaded"}},
        "stock" => fn %{"action" => "search"} -> {:ok, {:json, %{"results" => []}}, %{}} end
      })

      assert {:error, {:no_stock_found, _queries}} = Visuals.find(client, @scene)
    end
  end
end
