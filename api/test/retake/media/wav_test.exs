defmodule Retake.Media.WavTest do
  use ExUnit.Case, async: true

  alias Retake.Media.Wav

  @fixture Path.expand("../../../../fixtures/media/vo-minimal.wav", __DIR__)

  # --- building WAV files ------------------------------------------------------------------

  defp chunk(id, body) do
    pad = if rem(byte_size(body), 2) == 1, do: <<0>>, else: <<>>
    id <> <<byte_size(body)::little-32>> <> body <> pad
  end

  defp fmt(sample_rate, channels, bits) do
    byte_rate = sample_rate * channels * div(bits, 8)

    chunk(
      "fmt ",
      <<1::little-16, channels::little-16, sample_rate::little-32, byte_rate::little-32,
        channels * div(bits, 8)::little-16, bits::little-16>>
    )
  end

  defp data(byte_count, size_field \\ nil) do
    "data" <> <<size_field || byte_count::little-32>> <> :binary.copy(<<0>>, byte_count)
  end

  defp riff(chunks), do: "RIFF" <> <<byte_size(chunks) + 4::little-32>> <> "WAVE" <> chunks

  # --- reading --------------------------------------------------------------------------------

  test "duration and format of a mono 16-bit file" do
    # 1.5 s at 24 kHz, 16-bit mono = 72000 bytes
    assert Wav.info(riff(fmt(24_000, 1, 16) <> data(72_000))) ==
             {:ok, %{duration_ms: 1500, sample_rate: 24_000, channels: 1, bits_per_sample: 16}}
  end

  test "stereo and a different rate" do
    # 2 s at 44.1 kHz stereo 16-bit
    assert {:ok, %{duration_ms: 2000, sample_rate: 44_100, channels: 2}} =
             Wav.info(riff(fmt(44_100, 2, 16) <> data(44_100 * 4 * 2)))
  end

  test "skips chunks before data, including an odd-sized one with its padding byte" do
    wav = riff(fmt(8_000, 1, 8) <> chunk("LIST", "odd") <> chunk("junk", "even") <> data(16_000))
    assert {:ok, %{duration_ms: 2000}} = Wav.info(wav)
  end

  test "a streamed file whose data size is 0xFFFFFFFF runs to the end of the bytes" do
    assert {:ok, %{duration_ms: 1000}} =
             Wav.info(riff(fmt(16_000, 1, 16) <> data(32_000, 0xFFFFFFFF)))
  end

  test "a data size of 0 runs to the end of the bytes" do
    assert {:ok, %{duration_ms: 1000}} = Wav.info(riff(fmt(16_000, 1, 16) <> data(32_000, 0)))
  end

  test "a data size larger than what was sent counts only what is there" do
    assert {:ok, %{duration_ms: 500}} =
             Wav.info(riff(fmt(16_000, 1, 16) <> data(16_000, 1_000_000)))
  end

  test "a data size smaller than the bytes after it counts only the declared size" do
    wav = riff(fmt(16_000, 1, 16) <> data(32_000, 16_000))
    assert {:ok, %{duration_ms: 500}} = Wav.info(wav)
  end

  test "an empty data chunk is zero milliseconds" do
    assert {:ok, %{duration_ms: 0}} = Wav.info(riff(fmt(16_000, 1, 16) <> data(0)))
  end

  test "the real fixture voice-over: 2.5 s at 24 kHz mono" do
    assert {:ok, %{duration_ms: 2500, sample_rate: 24_000, channels: 1, bits_per_sample: 16}} =
             @fixture |> File.read!() |> Wav.info()
  end

  # --- refusing ---------------------------------------------------------------------------------

  test "not a RIFF file" do
    assert Wav.info("hello world, this is not audio") == {:error, :not_riff}
    assert Wav.info(<<>>) == {:error, :not_riff}
    assert Wav.info("RIF") == {:error, :not_riff}
  end

  test "RIFF but not WAVE" do
    assert Wav.info("RIFF" <> <<4::little-32>> <> "AVI " <> "more") == {:error, :not_wave}
  end

  test "no data chunk" do
    assert Wav.info(riff(fmt(16_000, 1, 16))) == {:error, :no_data_chunk}
  end

  test "data before fmt" do
    assert Wav.info(riff(data(100) <> fmt(16_000, 1, 16))) == {:error, :no_fmt_chunk}
  end

  test "a fmt chunk that is too short or has zeros" do
    assert Wav.info(riff(chunk("fmt ", <<1, 0, 1, 0>>) <> data(10))) == {:error, :bad_fmt_chunk}
    assert Wav.info(riff(fmt(0, 1, 16) <> data(10))) == {:error, :bad_fmt_chunk}
  end

  test "a chunk that claims more bytes than there are" do
    assert Wav.info(riff(fmt(16_000, 1, 16) <> "LIST" <> <<1_000::little-32>> <> "short")) ==
             {:error, :truncated}
  end
end
