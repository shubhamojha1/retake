defmodule Retake.Media.Image do
  @moduledoc """
  Reads the size and the type of a JPEG or PNG from its first bytes. Pure Elixir on two
  simple containers, so no media library is involved (AGENTS.md rule 8).

  A PNG starts with an 8 byte signature and an `IHDR` chunk holding the size. A JPEG is a
  list of segments, each `0xFF`, a marker byte, and (for most markers) a 16 bit length that
  counts itself; the frame header (a "SOF" marker) holds the size and comes before the image
  data.
  """

  # SOF0 to SOF15 are frame headers, except C4 (Huffman tables), C8 (reserved) and CC
  # (arithmetic coding conditioning), which sit in the same range.
  @frame_markers Enum.to_list(0xC0..0xCF) -- [0xC4, 0xC8, 0xCC]

  @type info :: %{width: pos_integer(), height: pos_integer(), mime: String.t()}

  @doc "Width, height and mime type of an image's bytes."
  @spec dimensions(binary()) :: {:ok, info()} | {:error, atom()}
  def dimensions(<<0xFF, 0xD8, segments::binary>>), do: jpeg(segments)

  def dimensions(
        <<0x89, "PNG\r\n", 0x1A, "\n", _length::32, "IHDR", width::32, height::32, _rest::binary>>
      ) do
    size(width, height, "image/png")
  end

  def dimensions(_other), do: {:error, :unknown_format}

  # A fill byte: any number of 0xFF may come before a marker.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, _length::16, _precision, height::16, width::16, _rest::binary>>)
       when marker in @frame_markers do
    size(width, height, "image/jpeg")
  end

  # The image data (or its end) came before any frame header.
  defp jpeg(<<0xFF, marker, _rest::binary>>) when marker in [0xDA, 0xD9], do: {:error, :no_size}

  # Markers with no length: restart markers, the start of image and TEM.
  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD8 or marker == 0x01 do
    jpeg(rest)
  end

  defp jpeg(<<0xFF, marker, length::16, rest::binary>>) when marker != 0 and length >= 2 do
    skip = length - 2

    case rest do
      <<_segment::binary-size(skip), tail::binary>> -> jpeg(tail)
      _ -> {:error, :truncated}
    end
  end

  defp jpeg(<<>>), do: {:error, :truncated}
  defp jpeg(_other), do: {:error, :bad_jpeg}

  defp size(width, height, mime) when width > 0 and height > 0 do
    {:ok, %{width: width, height: height, mime: mime}}
  end

  defp size(_width, _height, _mime), do: {:error, :bad_size}
end
