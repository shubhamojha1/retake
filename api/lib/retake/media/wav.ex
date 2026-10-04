defmodule Retake.Media.Wav do
  @moduledoc """
  Reads the header of a WAV file: how long it plays and its format. Pure Elixir on a
  small, simple container, so no media library is involved (AGENTS.md rule 8).

  A WAV is a `RIFF` header and a list of chunks; `fmt ` says how the samples are laid
  out and `data` holds them. Some servers stream a WAV before its length is known and
  write 0 or 0xFFFFFFFF as the `data` size, or a size larger than what was sent: in
  those cases the data is taken to run to the end of the bytes.
  """

  @max_size 0xFFFFFFFF

  @type info :: %{
          duration_ms: non_neg_integer(),
          sample_rate: pos_integer(),
          channels: pos_integer(),
          bits_per_sample: pos_integer()
        }

  @doc "Duration and format of a WAV file's bytes."
  @spec info(binary()) :: {:ok, info()} | {:error, atom()}
  def info(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>), do: scan(chunks, nil)
  def info(<<"RIFF", _rest::binary>>), do: {:error, :not_wave}
  def info(_other), do: {:error, :not_riff}

  # Walks the chunks until `data`, remembering `fmt ` on the way.
  defp scan(<<"fmt ", size::little-32, rest::binary>>, _fmt) do
    with {:ok, body, after_chunk} <- take(rest, size),
         {:ok, fmt} <- parse_fmt(body) do
      scan(after_chunk, fmt)
    end
  end

  defp scan(<<"data", _size::little-32, _rest::binary>>, nil), do: {:error, :no_fmt_chunk}

  defp scan(<<"data", size::little-32, rest::binary>>, fmt) do
    data_bytes =
      if size in [0, @max_size] or size > byte_size(rest), do: byte_size(rest), else: size

    finish(fmt, data_bytes)
  end

  defp scan(<<_id::binary-size(4), size::little-32, rest::binary>>, fmt) do
    with {:ok, _body, after_chunk} <- take(rest, size), do: scan(after_chunk, fmt)
  end

  defp scan(_exhausted, _fmt), do: {:error, :no_data_chunk}

  # A chunk's body, then the byte of padding that follows an odd-sized one.
  defp take(rest, size) do
    padded = size + rem(size, 2)

    cond do
      size <= byte_size(rest) and padded <= byte_size(rest) ->
        <<body::binary-size(size), _pad::binary-size(padded - size), after_chunk::binary>> = rest
        {:ok, body, after_chunk}

      size <= byte_size(rest) ->
        <<body::binary-size(size), after_chunk::binary>> = rest
        {:ok, body, after_chunk}

      true ->
        {:error, :truncated}
    end
  end

  defp parse_fmt(
         <<_format::little-16, channels::little-16, sample_rate::little-32, byte_rate::little-32,
           _block_align::little-16, bits::little-16, _rest::binary>>
       )
       when channels > 0 and sample_rate > 0 and byte_rate > 0 and bits > 0 do
    {:ok,
     %{channels: channels, sample_rate: sample_rate, byte_rate: byte_rate, bits_per_sample: bits}}
  end

  defp parse_fmt(_other), do: {:error, :bad_fmt_chunk}

  defp finish(fmt, data_bytes) do
    {:ok,
     %{
       duration_ms: round(data_bytes * 1000 / fmt.byte_rate),
       sample_rate: fmt.sample_rate,
       channels: fmt.channels,
       bits_per_sample: fmt.bits_per_sample
     }}
  end
end
