defmodule Retake.Providers.Adapters.OpenAICompatibleTranscriptionTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Adapters
  alias Retake.Providers.Adapters.OpenAICompatibleTranscription, as: Transcription
  alias Retake.Providers.{Client, Config, Provider, Usage}
  alias Retake.Storage
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @stub Transcription

  @audio "RIFF....WAVEfmt fake audio bytes"

  @transcription %{
    "task" => "transcribe",
    "language" => "english",
    "duration" => 4.52,
    "text" => " Hello there, world.",
    "words" => [
      %{"word" => "Hello", "start" => 0.0, "end" => 0.42},
      %{"word" => " there,", "start" => 0.5, "end" => 0.91},
      %{"word" => "world.", "start" => 0.95, "end" => 1.3004},
      %{"word" => "  ", "start" => 1.4, "end" => 1.5}
    ]
  }

  defp provider(options \\ %{}) do
    %Provider{
      name: "groq-whisper",
      capability: :stt,
      adapter: "openai_compatible_transcription",
      api_key_env: "GROQ_API_KEY",
      options:
        Map.merge(
          %{
            "base_url" => "https://api.groq.com/openai/v1",
            "model" => "whisper-large-v3-turbo",
            "timestamp_granularity" => "word"
          },
          options
        )
    }
  end

  setup %{tmp_dir: dir} do
    storage = Local.new(Path.join(dir, "store"))
    {:ok, ref} = Storage.put(storage, @audio, "wav")
    %{storage: storage, uri: ref.uri, dir: dir}
  end

  # The server: parses the multipart upload and tells the test process what it got.
  defp serve(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart]))
      upload = conn.body_params["file"]
      send(test, {:request, conn, conn.body_params, File.read!(upload.path)})
      reply.(conn)
    end)
  end

  defp sent do
    assert_received {:request, conn, params, file}
    {conn, params, file}
  end

  defp request(uri, extra \\ %{}), do: request_with(provider(), uri, extra)

  defp request_with(provider, uri, extra \\ %{}) do
    Transcription.normalize_request(provider, Map.merge(%{"audio" => uri}, extra))
  end

  defp call(provider \\ provider(), key \\ "gsk-key", request, storage) do
    Transcription.call(provider, key, request, %{storage: storage})
  end

  test "the adapter is registered as openai_compatible_transcription" do
    assert Adapters.fetch("openai_compatible_transcription") == {:ok, Transcription}
  end

  describe "normalize_request/2" do
    test "asks for word timestamps and adds the provider's language", %{uri: uri} do
      assert Transcription.normalize_request(provider(%{"language" => "en"}), %{"audio" => uri}) ==
               %{"audio" => uri, "granularity" => "word", "language" => "en"}
    end

    test "no language unless one is set", %{uri: uri} do
      assert Transcription.normalize_request(provider(), %{"audio" => uri}) ==
               %{"audio" => uri, "granularity" => "word"}
    end

    test "the request's own language wins", %{uri: uri} do
      normalized =
        Transcription.normalize_request(provider(%{"language" => "en"}), %{
          "audio" => uri,
          "language" => "pt"
        })

      assert normalized["language"] == "pt"
    end
  end

  describe "the request" do
    test "is a multipart POST to <base_url>/audio/transcriptions with a bearer token", %{
      storage: storage,
      uri: uri
    } do
      serve(&Req.Test.json(&1, @transcription))
      assert {:ok, _, _} = call(request(uri), storage)

      {conn, _params, _file} = sent()
      assert conn.method == "POST"
      assert conn.host == "api.groq.com"
      assert conn.request_path == "/openai/v1/audio/transcriptions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer gsk-key"]
      assert [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type =~ "multipart/form-data"
    end

    test "carries the model, verbose_json and word timestamps", %{storage: storage, uri: uri} do
      serve(&Req.Test.json(&1, @transcription))
      call(request(uri), storage)

      {_conn, params, _file} = sent()
      assert params["model"] == "whisper-large-v3-turbo"
      assert params["response_format"] == "verbose_json"
      assert params["timestamp_granularities"] == ["word"]
    end

    test "uploads the stored audio as audio.<ext> with its content type", %{
      storage: storage,
      uri: uri
    } do
      serve(&Req.Test.json(&1, @transcription))
      call(request(uri), storage)

      {_conn, %{"file" => upload}, file} = sent()
      assert upload.filename == "audio.wav"
      assert upload.content_type == "audio/wav"
      assert file == @audio
    end

    test "sends the language only when there is one", %{storage: storage, uri: uri} do
      serve(&Req.Test.json(&1, @transcription))

      call(request(uri), storage)
      {_, params, _} = sent()
      refute Map.has_key?(params, "language")

      call(request_with(provider(%{"language" => "en"}), uri), storage)
      {_, params, _} = sent()
      assert params["language"] == "en"
    end

    test "sends no authorization header without a key", %{storage: storage, uri: uri} do
      serve(&Req.Test.json(&1, @transcription))
      call(provider(), nil, request(uri), storage)

      {conn, _, _} = sent()
      assert Plug.Conn.get_req_header(conn, "authorization") == []
    end
  end

  describe "the answer" do
    test "words in milliseconds, trimmed, with the blank one dropped", %{
      storage: storage,
      uri: uri
    } do
      serve(&Req.Test.json(&1, @transcription))

      assert call(request(uri), storage) ==
               {:ok,
                {:json,
                 %{
                   "language" => "english",
                   "duration_ms" => 4520,
                   "text" => "Hello there, world.",
                   "words" => [
                     %{"text" => "Hello", "start_ms" => 0, "end_ms" => 420},
                     %{"text" => "there,", "start_ms" => 500, "end_ms" => 910},
                     %{"text" => "world.", "start_ms" => 950, "end_ms" => 1300}
                   ]
                 }}, %{cost_usd: 0.0, units: %{"seconds" => 4.52}}}
    end

    test "an end before its start is raised to the start", %{storage: storage, uri: uri} do
      body = Map.put(@transcription, "words", [%{"word" => "odd", "start" => 2.0, "end" => 1.0}])
      serve(&Req.Test.json(&1, body))

      assert {:ok, {:json, %{"words" => [%{"start_ms" => 2000, "end_ms" => 2000}]}}, _} =
               call(request(uri), storage)
    end

    test "no words (silence) is an empty list, not an error", %{storage: storage, uri: uri} do
      serve(&Req.Test.json(&1, Map.put(@transcription, "words", [])))
      assert {:ok, {:json, %{"words" => []}}, _} = call(request(uri), storage)
    end

    test "a reply with no words at all is an error: the service ignored word timestamps", %{
      storage: storage,
      uri: uri
    } do
      serve(&Req.Test.json(&1, Map.delete(@transcription, "words")))

      assert {:error, {:unexpected_response, message}} = call(request(uri), storage)
      assert message =~ "word timestamps"
    end
  end

  describe "failures" do
    test "an HTTP error carries the status and message", %{storage: storage, uri: uri} do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "Rate limit reached"}})
      end)

      assert call(request(uri), storage) == {:error, {:http, 429, "Rate limit reached"}}
    end

    test "the API key is redacted if the service echoes it back", %{storage: storage, uri: uri} do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "bad key gsk-secret-1"}})
      end)

      assert call(provider(), "gsk-secret-1", request(uri), storage) ==
               {:error, {:http, 401, "bad key [redacted]"}}
    end

    test "a transport failure", %{storage: storage, uri: uri} do
      serve(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert call(request(uri), storage) == {:error, {:transport, :timeout}}
    end

    test "bad requests are rejected before anything is sent", %{storage: storage, uri: uri} do
      missing = "store://assets/#{String.duplicate("0", 64)}.wav"

      assert {:error, {:bad_request, _}} = call(%{"granularity" => "word"}, storage)
      assert {:error, {:bad_request, m1}} = call(request("/etc/passwd"), storage)
      assert m1 =~ "store://"
      assert {:error, {:bad_request, m2}} = call(request(missing), storage)
      assert m2 =~ "cannot be read"

      assert {:error, {:bad_request, m3}} =
               call(request(uri, %{"granularity" => "segment"}), storage)

      assert m3 =~ "word"
      refute_received {:request, _, _, _}
    end

    test "provider configuration problems", %{storage: storage, uri: uri} do
      assert {:error, {:bad_provider_config, m1}} =
               call(provider(%{"base_url" => nil}), "k", request(uri), storage)

      assert m1 =~ "base_url"

      assert {:error, {:bad_provider_config, m2}} =
               call(provider(%{"model" => ""}), "k", request(uri), storage)

      assert m2 =~ "model"
    end

    test "called without a client (no storage) it explains itself", %{uri: uri} do
      assert {:error, {:bad_request, message}} =
               Transcription.call(provider(), "k", %{"audio" => uri})

      assert message =~ "Client"
    end
  end

  describe "through the Client" do
    @toml """
    [retake]
    default_profile = "dev"

    [profiles.dev]
    llm = { use = "x", fallbacks = [] }
    tts = { use = "x", fallbacks = [] }
    stt = { use = "whisper", fallbacks = [] }
    stock = { use = "x", fallbacks = [] }
    music = { use = "x", fallbacks = [] }

    [providers.x]
    capability = "any"
    adapter = "fake"

    [providers.whisper]
    capability = "stt"
    adapter = "openai_compatible_transcription"
    api_key_env = "GROQ_API_KEY"
    base_url = "https://api.groq.com/openai/v1"
    model = "whisper-large-v3-turbo"
    language = "en"
    """

    test "gets the storage, fills in defaults, and a repeat never reaches the server", %{
      dir: dir,
      storage: storage,
      uri: uri
    } do
      {:ok, config} = Config.parse(@toml)

      client =
        Client.new(
          config: config,
          profile: "dev",
          storage: storage,
          cache_root: Path.join(dir, "cache"),
          env: %{"GROQ_API_KEY" => "gsk-1"},
          usage: start_supervised!(Usage)
        )

      test = self()

      Req.Test.expect(@stub, fn conn ->
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart]))
        send(test, {:language, conn.body_params["language"]})
        Req.Test.json(conn, @transcription)
      end)

      assert {:ok, entry, :miss} = Client.call(client, :stt, %{"audio" => uri})
      assert_received {:language, "en"}
      assert entry.request == %{"audio" => uri, "granularity" => "word", "language" => "en"}
      assert {:json, %{"words" => [_, _, _]}} = entry.result

      assert {:ok, ^entry, :hit} = Client.call(client, :stt, %{"audio" => uri})
    end
  end
end
