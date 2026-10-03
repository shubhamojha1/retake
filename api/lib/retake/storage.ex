defmodule Retake.Storage do
  @moduledoc """
  Where generated and downloaded assets live, behind a behaviour (decision D7).

  Assets are content-addressed: `store://assets/<sha256 hex>.<ext>` (decision D20).
  The same bytes are stored once, and the uri is its own integrity check
  (`verify/2`). A storage is a `{module, config}` tuple; `Retake.Storage.Local`
  is the only backend so far (an S3-compatible one comes later).
  """

  @type t :: {module(), term()}
  @type ref :: %{uri: String.t(), content_hash: String.t(), size: non_neg_integer()}

  @callback put(config :: term(), bytes :: binary(), extension :: String.t()) ::
              {:ok, ref()} | {:error, :invalid_extension | term()}
  @callback fetch(config :: term(), uri :: String.t()) ::
              {:ok, binary()} | {:error, :not_found | :invalid_uri | term()}
  @callback exists?(config :: term(), uri :: String.t()) :: boolean()
  @callback local_path(config :: term(), uri :: String.t()) ::
              {:ok, Path.t()} | {:error, :not_found | :invalid_uri}

  @uri ~r|\Astore://assets/([0-9a-f]{64})\.([a-z0-9]{1,8})\z|
  @extension ~r/\A[a-z0-9]{1,8}\z/

  @doc "Stores `bytes` and returns its uri, content hash and size. Idempotent."
  @spec put(t(), binary(), String.t()) :: {:ok, ref()} | {:error, term()}
  def put({module, config}, bytes, extension), do: module.put(config, bytes, extension)

  @spec fetch(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch({module, config}, uri), do: module.fetch(config, uri)

  @spec exists?(t(), String.t()) :: boolean()
  def exists?({module, config}, uri), do: module.exists?(config, uri)

  @doc "An absolute file path for the asset, for programs that need a real file (the renderer)."
  @spec local_path(t(), String.t()) :: {:ok, Path.t()} | {:error, :not_found | :invalid_uri}
  def local_path({module, config}, uri), do: module.local_path(config, uri)

  @doc "Re-hashes the stored bytes and checks them against the hash in the uri."
  @spec verify(t(), String.t()) ::
          :ok | {:error, :not_found | :invalid_uri | :hash_mismatch | term()}
  def verify(storage, uri) do
    with {:ok, %{hash: hash}} <- parse_uri(uri),
         {:ok, bytes} <- fetch(storage, uri) do
      if content_hash(bytes) == "sha256:" <> hash, do: :ok, else: {:error, :hash_mismatch}
    end
  end

  @doc "`sha256:<hex>`, the format of an asset's `content_hash` in the spec."
  @spec content_hash(binary()) :: String.t()
  def content_hash(bytes), do: "sha256:" <> hex_digest(bytes)

  @doc false
  def hex_digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc false
  def parse_uri(uri) when is_binary(uri) do
    case Regex.run(@uri, uri) do
      [_, hash, extension] -> {:ok, %{hash: hash, extension: extension}}
      nil -> {:error, :invalid_uri}
    end
  end

  def parse_uri(_other), do: {:error, :invalid_uri}

  @doc false
  def build_uri(hash, extension), do: "store://assets/#{hash}.#{extension}"

  @doc false
  def normalize_extension(extension) when is_binary(extension) do
    extension = String.downcase(extension)

    if Regex.match?(@extension, extension),
      do: {:ok, extension},
      else: {:error, :invalid_extension}
  end

  def normalize_extension(_other), do: {:error, :invalid_extension}
end
