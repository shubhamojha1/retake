defmodule Retake.StorageTest do
  use ExUnit.Case, async: true

  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  # sha256("hello")
  @hello "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

  setup %{tmp_dir: dir} do
    %{storage: Local.new(dir), dir: dir}
  end

  defp stored_files(dir), do: dir |> Path.join("assets") |> File.ls!() |> Enum.sort()

  describe "put/3" do
    test "stores bytes under their content hash", %{storage: storage} do
      assert {:ok, ref} = Storage.put(storage, "hello", "txt")

      assert ref == %{
               uri: "store://assets/#{@hello}.txt",
               content_hash: "sha256:#{@hello}",
               size: 5
             }
    end

    test "the same bytes are stored once", %{storage: storage, dir: dir} do
      {:ok, first} = Storage.put(storage, "hello", "txt")
      {:ok, second} = Storage.put(storage, "hello", "txt")

      assert first == second
      assert stored_files(dir) == ["#{@hello}.txt"]
    end

    test "different bytes get different uris", %{storage: storage} do
      {:ok, a} = Storage.put(storage, "hello", "txt")
      {:ok, b} = Storage.put(storage, "hello!", "txt")
      refute a.uri == b.uri
    end

    test "keeps the extension, lower-cased", %{storage: storage} do
      {:ok, ref} = Storage.put(storage, "x", "JPG")
      assert String.ends_with?(ref.uri, ".jpg")
    end

    test "rejects extensions that could escape or confuse the path", %{storage: storage} do
      for bad <- ["", "../x", "a/b", "a b", "toolongext", ".jpg", "tar.gz"] do
        assert Storage.put(storage, "x", bad) == {:error, :invalid_extension}, inspect(bad)
      end
    end

    test "leaves no temp files behind", %{storage: storage, dir: dir} do
      {:ok, _} = Storage.put(storage, "hello", "txt")
      assert Path.wildcard(Path.join(dir, "tmp/*")) == []
    end

    test "concurrent writers of the same bytes all succeed", %{storage: storage, dir: dir} do
      results =
        1..20
        |> Task.async_stream(fn _ -> Storage.put(storage, "hello", "txt") end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %{size: 5}}, &1))
      assert stored_files(dir) == ["#{@hello}.txt"]
    end
  end

  describe "reading" do
    test "fetch returns the bytes", %{storage: storage} do
      {:ok, ref} = Storage.put(storage, "hello", "txt")
      assert Storage.fetch(storage, ref.uri) == {:ok, "hello"}
    end

    test "unknown assets are not found", %{storage: storage} do
      uri = "store://assets/#{@hello}.txt"
      assert Storage.fetch(storage, uri) == {:error, :not_found}
      assert Storage.exists?(storage, uri) == false
      assert Storage.local_path(storage, uri) == {:error, :not_found}
      assert Storage.verify(storage, uri) == {:error, :not_found}
    end

    test "exists?", %{storage: storage} do
      {:ok, ref} = Storage.put(storage, "hello", "txt")
      assert Storage.exists?(storage, ref.uri)
    end

    test "local_path gives an absolute path the renderer can read", %{storage: storage} do
      {:ok, ref} = Storage.put(storage, "pixels", "jpg")
      assert {:ok, path} = Storage.local_path(storage, ref.uri)

      assert Path.type(path) == :absolute
      assert String.ends_with?(path, ".jpg")
      assert File.read!(path) == "pixels"
    end
  end

  describe "uris" do
    @bad_uris [
      "store://assets/../../etc/passwd",
      "store://assets/#{@hello}.txt/extra",
      "store://other/#{@hello}.txt",
      "store://assets/ZZ.txt",
      "store://assets/#{String.slice(@hello, 0, 63)}.txt",
      "store://assets/#{@hello}",
      "file:///etc/passwd",
      "assets/#{@hello}.txt",
      ""
    ]

    test "anything but a well-formed store uri is invalid", %{storage: storage} do
      for uri <- @bad_uris do
        assert Storage.fetch(storage, uri) == {:error, :invalid_uri}, uri
        assert Storage.exists?(storage, uri) == false, uri
        assert Storage.local_path(storage, uri) == {:error, :invalid_uri}, uri
        assert Storage.verify(storage, uri) == {:error, :invalid_uri}, uri
      end
    end
  end

  describe "verify/2" do
    test "ok when the stored bytes still match the uri", %{storage: storage} do
      {:ok, ref} = Storage.put(storage, "hello", "txt")
      assert Storage.verify(storage, ref.uri) == :ok
    end

    test "detects changed bytes", %{storage: storage} do
      {:ok, ref} = Storage.put(storage, "hello", "txt")
      {:ok, path} = Storage.local_path(storage, ref.uri)
      File.write!(path, "tampered")

      assert Storage.verify(storage, ref.uri) == {:error, :hash_mismatch}
    end
  end

  test "content_hash/1 is sha256 in the spec's format" do
    assert Storage.content_hash("hello") == "sha256:#{@hello}"
  end
end
