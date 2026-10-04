defmodule Retake.Providers.ClientFromFileTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Client
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @example Path.expand("../../../../config/providers.example.toml", __DIR__)

  @minimal """
  [retake]
  default_profile = "dev"

  [storage]
  backend = "local"
  root = "./.retake/store"

  [cache]
  root = "./.retake/cache"

  [profiles.dev]
  llm = { use = "a", fallbacks = [] }
  tts = { use = "a", fallbacks = [] }
  stt = { use = "a", fallbacks = [] }
  stock = { use = "a", fallbacks = [] }
  music = { use = "a", fallbacks = [] }

  [profiles.other]
  llm = { use = "a", fallbacks = [] }
  tts = { use = "a", fallbacks = [] }
  stt = { use = "a", fallbacks = [] }
  stock = { use = "a", fallbacks = [] }
  music = { use = "a", fallbacks = [] }

  [providers.a]
  capability = "any"
  adapter = "fake"
  """

  # <dir>/config/providers.toml, like the repository: paths in it are relative to <dir>.
  defp write_config(dir, toml) do
    path = Path.join([dir, "config", "providers.toml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, toml)
    path
  end

  test "the shipped example config builds a client on its default profile" do
    assert {:ok, client} = Client.from_file(@example, env: %{})
    assert client.profile == "free"
    assert client.cache_root == Path.expand("../../../../.retake/cache", __DIR__)
  end

  test "storage and cache directories are relative to the project root", %{tmp_dir: dir} do
    path = write_config(dir, @minimal)

    assert {:ok, client} = Client.from_file(path)
    assert client.storage == Local.new(Path.join(dir, ".retake/store"))
    assert client.cache_root == Path.join(dir, ".retake/cache")
    assert client.profile == "dev"
  end

  test "absolute directories are kept", %{tmp_dir: dir} do
    toml = String.replace(@minimal, ~s(root = "./.retake/cache"), ~s(root = "/var/cache/retake"))
    path = write_config(dir, toml)

    assert {:ok, client} = Client.from_file(path)
    assert client.cache_root == "/var/cache/retake"
  end

  test "directories default when the tables are missing", %{tmp_dir: dir} do
    toml =
      @minimal
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~r/^(backend|root) =/))
      |> Enum.join("\n")

    path = write_config(dir, toml)

    assert {:ok, client} = Client.from_file(path)
    assert client.cache_root == Path.join(dir, ".retake/cache")
    assert client.storage == Local.new(Path.join(dir, ".retake/store"))
  end

  test "the :profile option wins, then RETAKE_PROFILE, then the file's default", %{tmp_dir: dir} do
    path = write_config(dir, @minimal)

    assert {:ok, %{profile: "other"}} =
             Client.from_file(path, profile: "other", env: %{"RETAKE_PROFILE" => "dev"})

    assert {:ok, %{profile: "other"}} =
             Client.from_file(path, env: %{"RETAKE_PROFILE" => "other"})

    assert {:ok, %{profile: "dev"}} = Client.from_file(path, env: %{})
  end

  test "passes env, usage and video_id through", %{tmp_dir: dir} do
    path = write_config(dir, @minimal)
    env = %{"A_KEY" => "k"}

    assert {:ok, client} = Client.from_file(path, env: env, usage: :my_usage, video_id: "v1")
    assert {client.env, client.usage, client.video_id} == {env, :my_usage, "v1"}
  end

  test "an unknown profile is an error", %{tmp_dir: dir} do
    path = write_config(dir, @minimal)
    assert Client.from_file(path, profile: "nope") == {:error, {:unknown_profile, "nope"}}
  end

  test "an unsupported storage backend is an error", %{tmp_dir: dir} do
    path = write_config(dir, String.replace(@minimal, ~s(backend = "local"), ~s(backend = "s3")))
    assert Client.from_file(path) == {:error, {:unsupported_storage_backend, "s3"}}
  end

  test "an invalid file is reported as config errors", %{tmp_dir: dir} do
    path =
      write_config(
        dir,
        String.replace(@minimal, ~s(default_profile = "dev"), ~s(default_profile = "nope"))
      )

    assert {:error, [%{path: "retake.default_profile"}]} = Client.from_file(path)
  end

  test "a missing file is an error" do
    assert {:error, [%{path: ""}]} = Client.from_file("no/such/providers.toml")
  end
end
