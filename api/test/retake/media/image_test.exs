defmodule Retake.Media.ImageTest do
  use ExUnit.Case, async: true

  alias Retake.Media.Image
  alias Retake.Test.Images

  @fixtures Path.expand("../../../../fixtures/media", __DIR__)

  describe "dimensions/1 on a JPEG" do
    test "reads the size from the frame header" do
      assert Image.dimensions(Images.jpeg(1080, 1920)) ==
               {:ok, %{width: 1080, height: 1920, mime: "image/jpeg"}}
    end

    test "reads a real file (the 1350x2400 fixture photo)" do
      bytes = File.read!(Path.join(@fixtures, "gradient.jpg"))
      assert {:ok, %{width: 1350, height: 2400, mime: "image/jpeg"}} = Image.dimensions(bytes)
    end

    test "skips fill bytes before a marker" do
      <<soi::binary-size(2), rest::binary>> = Images.jpeg(640, 480)
      assert {:ok, %{width: 640, height: 480}} = Image.dimensions(soi <> <<0xFF>> <> rest)
    end

    test "a file cut off inside a segment is truncated" do
      assert Image.dimensions(<<0xFF, 0xD8, 0xFF, 0xE0, 16::16, "JF">>) == {:error, :truncated}
    end

    test "image data before any frame header means no size" do
      assert Image.dimensions(<<0xFF, 0xD8, 0xFF, 0xDA, 0, 2>>) == {:error, :no_size}
    end

    test "a zero size is refused" do
      assert Image.dimensions(Images.jpeg(0, 100)) == {:error, :bad_size}
    end

    test "bytes that are not a marker after the start are refused" do
      assert Image.dimensions(<<0xFF, 0xD8, 1, 2, 3>>) == {:error, :bad_jpeg}
    end
  end

  describe "dimensions/1 on a PNG" do
    test "reads the size from IHDR" do
      assert Image.dimensions(Images.png(1024, 1792)) ==
               {:ok, %{width: 1024, height: 1792, mime: "image/png"}}
    end

    test "a zero size is refused" do
      assert Image.dimensions(Images.png(0, 5)) == {:error, :bad_size}
    end
  end

  describe "dimensions/1 on anything else" do
    test "is an unknown format" do
      assert Image.dimensions("<html>sorry</html>") == {:error, :unknown_format}
      assert Image.dimensions(<<>>) == {:error, :unknown_format}
      assert Image.dimensions("GIF89a...") == {:error, :unknown_format}
    end
  end
end
