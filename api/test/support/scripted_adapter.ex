defmodule Retake.Test.ScriptedAdapter do
  @moduledoc """
  A stand-in for every provider, for tests that run the whole pipeline offline. Unlike
  `Retake.Test.FakeAdapter` it holds no per-process state, so it works from the pipeline's
  scene tasks. What a provider does is set by its `role` option:

    * `"llm"`: answers with a fixed three-scene script (a video scene, then two photo scenes);
    * `"stock"`: finds the fixture clip for a query containing "clip", the fixture photos for
      "gradient" and "sea", nothing otherwise, and "downloads" the real fixture files
      (`fixtures/media`);
    * `"image"`: "paints" the fixture photo `gradient.jpg` (1350x2400) for any prompt;
    * `"tts"`: a silent 24 kHz WAV, 400 ms a word;
    * `"stt"`: reads that WAV from the storage and returns one word per 400 ms.

  Options for a failure test: `fail = true` (the provider always fails with an HTTP 503),
  `empty_for = "sea"` (a stock search whose query contains this finds nothing), and
  `log = "/path"` (one line per call is appended, so a test can tell what was called).
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Media.Wav
  alias Retake.Storage

  @fixtures Path.expand("../../../fixtures/media", __DIR__)
  @ms_per_word 400

  @script %{
    "title" => "Tea in three scenes",
    "scenes" => [
      %{
        "narration" => "Tea wakes you up gently.",
        "visual_query" => "clip video steam",
        "on_screen_text" => "Wake Up"
      },
      %{
        "narration" => "It is full of antioxidants.",
        "visual_query" => "photo gradient leaves",
        "image_prompt" => "A calm sea at sunrise, vertical shot, soft light."
      },
      %{"narration" => "So sip it every day.", "visual_query" => "photo sea sunrise"}
    ]
  }

  @impl true
  def call(_provider, _api_key, _request), do: {:error, :needs_a_client}

  @impl true
  def call(provider, _api_key, request, context) do
    log(provider, request)

    if provider.options["fail"] do
      {:error, {:http, 503, "scripted failure"}}
    else
      answer(provider.options["role"], provider, request, context)
    end
  end

  # --- the roles ---------------------------------------------------------------------------

  defp answer("llm", _provider, _request, _context) do
    reply = %{"content" => Jason.encode!(@script), "finish_reason" => "stop"}
    {:ok, {:json, reply}, %{cost_usd: 0.0, units: %{}}}
  end

  defp answer(
         "stock",
         provider,
         %{"action" => "search", "kind" => kind, "query" => query},
         _context
       ) do
    skip = provider.options["empty_for"]
    results = if skip && String.contains?(query, skip), do: [], else: candidates(kind, query)
    {:ok, {:json, %{"results" => results}}, %{cost_usd: 0.0, units: %{}}}
  end

  defp answer("stock", _provider, %{"action" => "download", "url" => url}, _context) do
    file = Path.basename(url)

    {:ok,
     {:binary, File.read!(Path.join(@fixtures, file)),
      Path.extname(file) |> String.trim_leading(".")}, %{cost_usd: 0.0, units: %{}}}
  end

  defp answer("tts", _provider, %{"text" => text}, _context) do
    ms = length(String.split(text)) * @ms_per_word

    {:ok, {:binary, silent_wav(ms), "wav"},
     %{cost_usd: 0.0, units: %{"characters" => String.length(text)}}}
  end

  defp answer("stt", _provider, %{"audio" => uri}, %{storage: storage}) do
    {:ok, bytes} = Storage.fetch(storage, uri)
    {:ok, %{duration_ms: duration}} = Wav.info(bytes)
    count = max(div(duration, @ms_per_word), 1)

    words =
      for i <- 0..(count - 1) do
        %{
          "text" => "word#{i + 1}",
          "start_ms" => i * @ms_per_word,
          "end_ms" => i * @ms_per_word + 350
        }
      end

    output = %{"language" => "english", "duration_ms" => duration, "text" => "", "words" => words}
    {:ok, {:json, output}, %{cost_usd: 0.0, units: %{"seconds" => duration / 1000}}}
  end

  defp answer("image", _provider, %{"prompt" => _prompt}, _context) do
    {:ok, {:binary, File.read!(Path.join(@fixtures, "gradient.jpg")), "jpg"},
     %{cost_usd: 0.0, units: %{"steps" => 4}}}
  end

  defp answer(role, _provider, request, _context) do
    {:error, {:scripted_adapter_cannot_answer, role, request}}
  end

  # --- stock candidates --------------------------------------------------------------------

  defp candidates("video", query) do
    if String.contains?(query, "clip"),
      do: [candidate("video", "clip.mp4", 720, 1280, 6_000)],
      else: []
  end

  defp candidates("photo", query) do
    cond do
      String.contains?(query, "gradient") -> [candidate("photo", "gradient.jpg", 1350, 2400, nil)]
      String.contains?(query, "sea") -> [candidate("photo", "sea.jpg", 1350, 2400, nil)]
      true -> []
    end
  end

  defp candidate(kind, file, width, height, duration_ms) do
    mime = if kind == "video", do: "video/mp4", else: "image/jpeg"

    %{
      "kind" => kind,
      "id" => file,
      "page_url" => "https://scripted.test/#{file}",
      "creator" => "Test Creator",
      "creator_url" => "https://scripted.test/@creator",
      "duration_ms" => duration_ms,
      "source" => "Scripted",
      "license" => %{"name" => "Test License", "url" => "https://scripted.test/license"},
      "files" => [
        %{
          "url" => "https://scripted.test/files/#{file}",
          "width" => width,
          "height" => height,
          "mime" => mime
        }
      ]
    }
  end

  # --- audio ---------------------------------------------------------------------------------

  defp silent_wav(ms) do
    data = :binary.copy(<<0>>, div(ms * 48_000, 1000))

    fmt =
      "fmt " <>
        <<16::little-32, 1::little-16, 1::little-16, 24_000::little-32, 48_000::little-32,
          2::little-16, 16::little-16>>

    body = "WAVE" <> fmt <> "data" <> <<byte_size(data)::little-32>> <> data
    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end

  defp log(provider, request) do
    if path = provider.options["log"] do
      File.write!(path, "#{provider.name} #{request["action"] || ""}\n", [:append])
    end
  end
end
