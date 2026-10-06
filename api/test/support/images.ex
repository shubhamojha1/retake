defmodule Retake.Test.Images do
  @moduledoc """
  Tiny image files for tests: just enough of a JPEG or a PNG for `Retake.Media.Image` to
  read its size. They are not viewable pictures.
  """

  @doc "The start of a baseline JPEG: JFIF header, then a frame header carrying the size."
  @spec jpeg(pos_integer(), pos_integer()) :: binary()
  def jpeg(width, height) do
    <<0xFF, 0xD8>> <>
      <<0xFF, 0xE0, 16::16, "JFIF", 0, 1, 1, 0, 1::16, 1::16, 0, 0>> <>
      <<0xFF, 0xC0, 17::16, 8, height::16, width::16, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1>>
  end

  @doc "A PNG signature and its IHDR chunk."
  @spec png(pos_integer(), pos_integer()) :: binary()
  def png(width, height) do
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", width::32, height::32, 8, 2, 0, 0, 0>>
  end
end
