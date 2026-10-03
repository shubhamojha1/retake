defmodule Retake.Storage.Local do
  @moduledoc """
  `Retake.Storage` on the local disk, under one root directory:

      <root>/assets/<sha256 hex>.<ext>    the assets
      <root>/tmp/                         files being written

  A write goes to `tmp/` first and is renamed into `assets/`, so a reader never
  sees half a file. Uris are parsed strictly (`Retake.Storage.parse_uri/1`), so no
  path component can come from untrusted input.
  """

  @behaviour Retake.Storage

  alias Retake.Storage

  @doc "A storage backed by the directory `root` (created on first write)."
  @spec new(Path.t()) :: Storage.t()
  def new(root), do: {__MODULE__, Path.expand(root)}

  @impl true
  def put(root, bytes, extension) do
    with {:ok, extension} <- Storage.normalize_extension(extension) do
      hash = Storage.hex_digest(bytes)

      ref = %{
        uri: Storage.build_uri(hash, extension),
        content_hash: "sha256:" <> hash,
        size: byte_size(bytes)
      }

      path = asset_path(root, hash, extension)

      cond do
        File.regular?(path) -> {:ok, ref}
        true -> write_atomically(root, path, bytes, ref)
      end
    end
  end

  @impl true
  def fetch(root, uri) do
    with {:ok, path} <- path_for(root, uri) do
      case File.read(path) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def exists?(root, uri) do
    match?({:ok, _}, local_path(root, uri))
  end

  @impl true
  def local_path(root, uri) do
    with {:ok, path} <- path_for(root, uri) do
      if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
    end
  end

  defp path_for(root, uri) do
    with {:ok, %{hash: hash, extension: extension}} <- Storage.parse_uri(uri) do
      {:ok, asset_path(root, hash, extension)}
    end
  end

  defp asset_path(root, hash, extension), do: Path.join([root, "assets", "#{hash}.#{extension}"])

  defp write_atomically(root, path, bytes, ref) do
    temp_dir = Path.join(root, "tmp")

    temp =
      Path.join(
        temp_dir,
        "#{ref.content_hash |> String.slice(7, 16)}.#{System.unique_integer([:positive])}.part"
      )

    with :ok <- File.mkdir_p(temp_dir),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, bytes),
         :ok <- File.rename(temp, path) do
      {:ok, ref}
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end
end
