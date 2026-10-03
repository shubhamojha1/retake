defmodule Retake.Cache do
  @moduledoc """
  The request cache (decisions D6, D18, D19): the same request is never paid for
  twice. A request is identified by `request_hash/3`; each result is one JSON file
  `<root>/<hex>.json` (`Retake.Cache.Entry`).

  `fetch_or_run/5` returns the stored result without calling the producer when it
  can. Failures are never cached. A cached asset that is no longer in storage, or
  a cache file that is damaged, counts as a miss and is replaced. A failure to
  write the cache file is logged, not raised: the provider has already been paid.

  There is no single-flight: two identical requests running at the same moment
  can both call the provider.
  """

  require Logger

  alias Retake.Cache.Entry
  alias Retake.Storage

  @type parts :: %{
          capability: atom(),
          provider: String.t(),
          model: String.t(),
          request: map()
        }
  @type output :: {:json, term()} | {:binary, binary(), String.t()}
  @type producer :: (-> {:ok, output(), map()} | {:error, term()})

  @doc """
  `sha256:<hex>` of the canonical JSON of `[provider, model, request]`. This is
  how every `request_hash` in `spec/examples/` was made (decision D18).
  """
  @spec request_hash(String.t(), String.t(), map()) :: String.t()
  def request_hash(provider, model, request) do
    "sha256:" <> Storage.hex_digest(canonical_json([provider, model, request]))
  end

  @doc """
  JSON the way Python's `json.dumps(term, sort_keys=True)` writes it: keys sorted,
  separators `", "` and `": "`, non-ASCII escaped as `\\uXXXX`.

  Atom keys and values are written as strings. A map holding the same key as an
  atom and as a string raises. Floats use Elixir's shortest form, which equals
  Python's for ordinary values (`1.0`, `0.5`).
  """
  @spec canonical_json(term()) :: String.t()
  def canonical_json(term), do: term |> encode() |> IO.iodata_to_binary()

  @doc """
  Returns the cached entry for this request, or calls `producer` and caches what
  it returns. The producer returns `{:ok, output, meta}` where `output` is
  `{:json, term}` or `{:binary, bytes, extension}` (stored in `storage`) and
  `meta` may carry `:cost` (`%{amount, currency, units}`), or `{:error, reason}`.

  Returns `{:ok, entry, :hit | :miss}`. Options: `:force` (skip the lookup and
  replace the entry), `:now` (a `DateTime`, for tests).
  """
  @spec fetch_or_run(Path.t(), Storage.t(), parts(), producer(), keyword()) ::
          {:ok, Entry.t(), :hit | :miss} | {:error, term()}
  def fetch_or_run(root, storage, parts, producer, opts \\ []) do
    hash = request_hash(parts.provider, parts.model, parts.request)
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.truncate(:second)

    with false <- Keyword.get(opts, :force, false),
         {:ok, entry} <- load(root, hash, storage) do
      {:ok, entry, :hit}
    else
      _miss -> produce(root, storage, parts, hash, producer, now)
    end
  end

  # --- reading -------------------------------------------------------------------

  defp load(root, hash, storage) do
    with {:ok, body} <- File.read(entry_path(root, hash)),
         {:ok, json} <- Jason.decode(body),
         {:ok, entry} <- Entry.from_json(json),
         true <- entry.request_hash == hash,
         true <- asset_present?(entry, storage) do
      {:ok, entry}
    else
      _ -> :miss
    end
  end

  defp asset_present?(%Entry{result: {:asset, %{uri: uri}}}, storage),
    do: Storage.exists?(storage, uri)

  defp asset_present?(%Entry{}, _storage), do: true

  # --- producing ---------------------------------------------------------------------

  defp produce(root, storage, parts, hash, producer, now) do
    case producer.() do
      {:ok, output, meta} ->
        with {:ok, result} <- store_result(storage, output) do
          entry = %Entry{
            request_hash: hash,
            capability: parts.capability,
            provider: parts.provider,
            model: parts.model,
            request: json_roundtrip(parts.request),
            created_at: now,
            cost: cost(meta),
            result: result
          }

          save(root, entry)
          {:ok, entry, :miss}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_producer_result, other}}
    end
  end

  defp store_result(_storage, {:json, value}), do: {:ok, {:json, value}}

  defp store_result(storage, {:binary, bytes, extension}) do
    case Storage.put(storage, bytes, extension) do
      {:ok, ref} -> {:ok, {:asset, ref}}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp store_result(_storage, other), do: {:error, {:invalid_producer_output, other}}

  # What a hit would read back, so a miss and a hit return equal entries.
  defp json_roundtrip(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp cost(%{cost: %{amount: amount, currency: currency} = cost}) do
    %{amount: amount * 1.0, currency: currency, units: Map.get(cost, :units, %{})}
  end

  defp cost(_meta), do: %{amount: 0.0, currency: "USD", units: %{}}

  defp save(root, %Entry{request_hash: hash} = entry) do
    path = entry_path(root, hash)
    temp = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(temp, Jason.encode!(Entry.to_json(entry), pretty: true)),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        Logger.warning("could not write cache entry #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp entry_path(root, "sha256:" <> hex), do: Path.join(root, hex <> ".json")

  # --- canonical JSON ---------------------------------------------------------------

  defp encode(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> {key_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))

    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) != length(keys) do
      raise ArgumentError, "map has the same key as an atom and as a string: #{inspect(map)}"
    end

    members = Enum.map(pairs, fn {key, value} -> [encode_string(key), ": ", encode(value)] end)
    ["{", Enum.intersperse(members, ", "), "}"]
  end

  defp encode(list) when is_list(list),
    do: ["[", list |> Enum.map(&encode/1) |> Enum.intersperse(", "), "]"]

  defp encode(nil), do: "null"
  defp encode(true), do: "true"
  defp encode(false), do: "false"
  defp encode(string) when is_binary(string), do: encode_string(string)
  defp encode(integer) when is_integer(integer), do: Integer.to_string(integer)
  defp encode(float) when is_float(float), do: Jason.encode!(float)
  defp encode(atom) when is_atom(atom), do: encode_string(Atom.to_string(atom))

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)

  defp key_string(key),
    do: raise(ArgumentError, "request keys must be strings or atoms, got: #{inspect(key)}")

  # Python's ensure_ascii escaping: short escapes for the usual controls, \u00XX for
  # the rest, \uXXXX (lower-case hex, surrogate pairs above U+FFFF) for non-ASCII.
  defp encode_string(string) do
    escaped = for <<codepoint::utf8 <- string>>, into: "", do: escape(codepoint)
    ["\"", escaped, "\""]
  end

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(?\n), do: "\\n"
  defp escape(?\r), do: "\\r"
  defp escape(?\t), do: "\\t"
  defp escape(?\b), do: "\\b"
  defp escape(?\f), do: "\\f"
  defp escape(codepoint) when codepoint < 0x20, do: unicode_escape(codepoint)
  defp escape(codepoint) when codepoint < 0x80, do: <<codepoint>>
  defp escape(codepoint) when codepoint <= 0xFFFF, do: unicode_escape(codepoint)

  defp escape(codepoint) do
    offset = codepoint - 0x10000

    unicode_escape(0xD800 + Bitwise.bsr(offset, 10)) <>
      unicode_escape(0xDC00 + Bitwise.band(offset, 0x3FF))
  end

  defp unicode_escape(value) do
    "\\u" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end
end
