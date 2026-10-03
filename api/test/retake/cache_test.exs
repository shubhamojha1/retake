defmodule Retake.CacheTest do
  use ExUnit.Case, async: true

  alias Retake.Cache
  alias Retake.Cache.Entry
  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @examples Path.expand("../../../spec/examples", __DIR__)
  @now ~U[2026-10-04 12:00:00Z]

  setup %{tmp_dir: dir} do
    %{cache: Path.join(dir, "cache"), storage: Local.new(Path.join(dir, "store")), dir: dir}
  end

  # --- request_hash (D18) ----------------------------------------------------------

  describe "request_hash/3" do
    test "reproduces every request_hash in spec/examples/explainer.json" do
      spec = @examples |> Path.join("explainer.json") |> File.read!() |> Jason.decode!()

      provenances =
        for {_id, %{"provenance" => %{"request_hash" => _} = provenance}} <- spec["assets"],
            do: provenance

      assert length(provenances) == 6

      for p <- provenances do
        assert Cache.request_hash(p["provider"], p["model"], p["request"]) == p["request_hash"],
               "#{p["provider"]} #{inspect(p["request"])}"
      end
    end

    # Reference values computed with Python:
    #   json.dumps([provider, model, request], sort_keys=True), then sha256.
    test "matches the Python reference for non-ASCII text and floats" do
      request = %{"text" => "café ☕", "speed" => 0.5, "n" => 3}

      assert Cache.request_hash("p", "m", request) ==
               "sha256:c3fb863fc632903dc022132f5a0ad5378712d48b3d3e95fa388ea44c73459361"
    end

    test "matches the Python reference for characters outside the BMP (surrogate pairs)" do
      assert Cache.request_hash("p", "m", %{"text" => "😀 ok"}) ==
               "sha256:683f7c2b09a5216425d1446c2a928348abda560824c37787cee95a259c1ff25f"
    end

    test "matches the Python reference for nesting, escapes, null and booleans" do
      request = %{
        "a" => %{
          "z" => [1, 2.5, nil, true, false],
          "b" => "line\nbreak \"q\" back\\slash tab\t"
        }
      }

      assert Cache.request_hash("p", "m", request) ==
               "sha256:59cfd11a04e958367afbc6f47e824976c3adc6446a8b488b837c0289bb85f33e"
    end

    test "does not depend on key order or on atom versus string keys" do
      a = Cache.request_hash("p", "m", %{"x" => 1, "y" => %{"b" => 2, "a" => 3}})
      b = Cache.request_hash("p", "m", %{y: %{a: 3, b: 2}, x: 1})
      assert a == b
    end

    test "provider, model and request all matter" do
      base = Cache.request_hash("p", "m", %{"t" => "x"})
      refute base == Cache.request_hash("q", "m", %{"t" => "x"})
      refute base == Cache.request_hash("p", "n", %{"t" => "x"})
      refute base == Cache.request_hash("p", "m", %{"t" => "y"})
    end

    test "list order matters" do
      refute Cache.request_hash("p", "m", %{"l" => [1, 2]}) ==
               Cache.request_hash("p", "m", %{"l" => [2, 1]})
    end

    test "a map with the same key as an atom and a string is ambiguous and rejected" do
      assert_raise ArgumentError, fn -> Cache.request_hash("p", "m", %{:a => 1, "a" => 2}) end
    end
  end

  describe "canonical_json/1" do
    test "sorts keys and uses Python's separators" do
      assert Cache.canonical_json(["p", "m", %{"b" => 1, "a" => [true, nil, "x"]}]) ==
               ~s(["p", "m", {"a": [true, null, "x"], "b": 1}])
    end
  end

  # --- fetch_or_run ------------------------------------------------------------------

  defp parts(overrides \\ %{}) do
    Map.merge(
      %{
        capability: :tts,
        provider: "kokoro-local",
        model: "kokoro-82m",
        request: %{"text" => "hello", "voice" => "af_heart", "speed" => 1.0}
      },
      overrides
    )
  end

  defp cost(amount), do: %{cost: %{amount: amount, currency: "USD", units: %{"chars" => 5}}}

  # A producer that tells the test process each time it runs.
  defp producer(result) do
    test = self()

    fn ->
      send(test, :produced)
      result
    end
  end

  defp run(ctx, producer, overrides \\ %{}, opts \\ []) do
    Cache.fetch_or_run(
      ctx.cache,
      ctx.storage,
      parts(overrides),
      producer,
      Keyword.put_new(opts, :now, @now)
    )
  end

  describe "fetch_or_run/5" do
    test "a repeated request does not call the producer again", ctx do
      producer = producer({:ok, {:json, %{"title" => "x"}}, cost(0.0)})

      assert {:ok, %Entry{result: {:json, %{"title" => "x"}}}, :miss} = run(ctx, producer)
      assert_received :produced

      assert {:ok, %Entry{result: {:json, %{"title" => "x"}}}, :hit} = run(ctx, producer)
      refute_received :produced
    end

    test "binary results are stored and cached as an asset", ctx do
      producer = producer({:ok, {:binary, "RIFF-audio", "wav"}, cost(0.0)})

      assert {:ok, %Entry{result: {:asset, ref}}, :miss} = run(ctx, producer)
      assert ref.content_hash == Storage.content_hash("RIFF-audio")
      assert ref.size == 10
      assert Storage.fetch(ctx.storage, ref.uri) == {:ok, "RIFF-audio"}

      assert {:ok, %Entry{result: {:asset, ^ref}}, :hit} = run(ctx, producer)
      assert length(Path.wildcard(Path.join(ctx.dir, "store/assets/*"))) == 1
    end

    test "the entry records the request hash, provenance and cost", ctx do
      {:ok, entry, :miss} = run(ctx, producer({:ok, {:json, 1}, cost(0.02)}))

      assert entry.request_hash ==
               Cache.request_hash("kokoro-local", "kokoro-82m", parts().request)

      assert entry.provider == "kokoro-local"
      assert entry.model == "kokoro-82m"
      assert entry.capability == :tts
      assert entry.created_at == @now
      assert entry.cost == %{amount: 0.02, currency: "USD", units: %{"chars" => 5}}
    end

    test "a hit still shows the original cost: it is the asset's provenance", ctx do
      producer = producer({:ok, {:json, 1}, cost(0.02)})
      {:ok, _, :miss} = run(ctx, producer)
      {:ok, entry, :hit} = run(ctx, producer)
      assert entry.cost.amount == 0.02
    end

    test "cost defaults to zero USD", ctx do
      {:ok, entry, :miss} = run(ctx, producer({:ok, {:json, 1}, %{}}))
      assert entry.cost == %{amount: 0.0, currency: "USD", units: %{}}
    end

    test "writes one readable JSON file per request hash", ctx do
      {:ok, entry, :miss} = run(ctx, producer({:ok, {:json, %{"k" => "v"}}, cost(0.0)}))

      hex = String.replace_prefix(entry.request_hash, "sha256:", "")
      file = Path.join(ctx.cache, "#{hex}.json")
      saved = file |> File.read!() |> Jason.decode!()

      assert saved["request_hash"] == entry.request_hash
      assert saved["provider"] == "kokoro-local"
      assert saved["model"] == "kokoro-82m"
      assert saved["request"] == %{"text" => "hello", "voice" => "af_heart", "speed" => 1.0}
      assert saved["created_at"] == "2026-10-04T12:00:00Z"
      assert saved["result"] == %{"type" => "json", "value" => %{"k" => "v"}}
    end

    test "a different request is a miss", ctx do
      producer = producer({:ok, {:json, 1}, cost(0.0)})
      {:ok, _, :miss} = run(ctx, producer)
      assert {:ok, _, :miss} = run(ctx, producer, %{request: %{"text" => "goodbye"}})
    end

    test "a different provider is a miss", ctx do
      producer = producer({:ok, {:json, 1}, cost(0.0)})
      {:ok, _, :miss} = run(ctx, producer)
      assert {:ok, _, :miss} = run(ctx, producer, %{provider: "openai-tts"})
    end

    test "failures are not cached", ctx do
      assert run(ctx, producer({:error, :boom})) == {:error, :boom}
      assert_received :produced

      assert {:ok, _, :miss} = run(ctx, producer({:ok, {:json, 1}, cost(0.0)}))
      assert_received :produced
    end

    test "force: true runs the producer again and replaces the entry", ctx do
      {:ok, _, :miss} = run(ctx, producer({:ok, {:json, "old"}, cost(0.0)}))
      assert_received :produced

      assert {:ok, %Entry{result: {:json, "new"}}, :miss} =
               run(ctx, producer({:ok, {:json, "new"}, cost(0.0)}), %{}, force: true)

      assert_received :produced
      assert {:ok, %Entry{result: {:json, "new"}}, :hit} = run(ctx, producer({:error, :unused}))
    end

    test "a cached asset that was deleted counts as a miss and is repaired", ctx do
      producer = producer({:ok, {:binary, "bytes", "bin"}, cost(0.0)})
      {:ok, %Entry{result: {:asset, ref}}, :miss} = run(ctx, producer)
      assert_received :produced

      {:ok, path} = Storage.local_path(ctx.storage, ref.uri)
      File.rm!(path)

      assert {:ok, %Entry{result: {:asset, ^ref}}, :miss} = run(ctx, producer)
      assert_received :produced
      assert Storage.exists?(ctx.storage, ref.uri)
      assert {:ok, _, :hit} = run(ctx, producer)
    end

    test "a corrupt cache file counts as a miss and is replaced", ctx do
      producer = producer({:ok, {:json, 1}, cost(0.0)})
      {:ok, entry, :miss} = run(ctx, producer)
      hex = String.replace_prefix(entry.request_hash, "sha256:", "")
      File.write!(Path.join(ctx.cache, "#{hex}.json"), "{ not json")

      assert {:ok, _, :miss} = run(ctx, producer)
      assert {:ok, _, :hit} = run(ctx, producer)
    end

    test "a cache file that is valid JSON but not an entry counts as a miss", ctx do
      producer = producer({:ok, {:json, 1}, cost(0.0)})
      {:ok, entry, :miss} = run(ctx, producer)
      hex = String.replace_prefix(entry.request_hash, "sha256:", "")
      File.write!(Path.join(ctx.cache, "#{hex}.json"), ~s|{"hello": "world"}|)

      assert {:ok, _, :miss} = run(ctx, producer)
    end
  end

  describe "Entry.provenance/1" do
    test "has the shape of a spec asset's provenance", ctx do
      {:ok, entry, :miss} = run(ctx, producer({:ok, {:json, 1}, cost(0.02)}))

      assert Entry.provenance(entry) == %{
               "source" => "generated",
               "capability" => "tts",
               "provider" => "kokoro-local",
               "model" => "kokoro-82m",
               "request" => %{"text" => "hello", "voice" => "af_heart", "speed" => 1.0},
               "request_hash" => entry.request_hash,
               "created_at" => "2026-10-04T12:00:00Z",
               "cost" => %{"amount" => 0.02, "currency" => "USD", "units" => %{"chars" => 5}}
             }
    end

    test "stock results are marked as stock", ctx do
      {:ok, entry, :miss} =
        run(ctx, producer({:ok, {:json, 1}, cost(0.0)}), %{capability: :stock})

      assert Entry.provenance(entry)["source"] == "stock"
      assert Entry.provenance(entry)["capability"] == "stock"
    end
  end
end
