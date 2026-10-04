defmodule Retake.Providers.Adapters.OpenAICompatibleSpeechTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Adapters
  alias Retake.Providers.Adapters.OpenAICompatibleSpeech, as: Speech
  alias Retake.Providers.Provider

  @stub Speech

  # A WAV file's first bytes: enough to pass the "is it a WAV" check.
  @wav "RIFF" <> <<36::little-32>> <> "WAVE" <> "fmt " <> :binary.copy(<<0>>, 24)

  defp provider(options \\ %{}) do
    %Provider{
      name: "kokoro-local",
      capability: :tts,
      adapter: "openai_compatible_speech",
      options:
        Map.merge(
          %{
            "base_url" => "http://localhost:8880/v1",
            "model" => "kokoro",
            "voice" => "af_heart",
            "speed" => 1.0,
            "format" => "wav"
          },
          options
        )
    }
  end

  defp serve(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, Jason.decode!(raw)})
      reply.(conn)
    end)
  end

  defp sent do
    assert_received {:request, conn, body}
    {conn, body}
  end

  defp audio(conn, bytes \\ @wav), do: Plug.Conn.send_resp(conn, 200, bytes)

  defp request(provider \\ provider(), extra \\ %{}) do
    Speech.normalize_request(provider, Map.merge(%{"text" => "Hello there."}, extra))
  end

  test "the adapter is registered as openai_compatible_speech" do
    assert Adapters.fetch("openai_compatible_speech") == {:ok, Speech}
  end

  describe "normalize_request/2" do
    test "fills in voice and speed from the provider" do
      assert Speech.normalize_request(provider(), %{"text" => "hi"}) ==
               %{"text" => "hi", "voice" => "af_heart", "speed" => 1.0}
    end

    test "the request's own values win" do
      assert Speech.normalize_request(provider(), %{
               "text" => "hi",
               "voice" => "bf_emma",
               "speed" => 1.2
             }) ==
               %{"text" => "hi", "voice" => "bf_emma", "speed" => 1.2}
    end

    test "settings the provider lacks are left out" do
      assert Speech.normalize_request(provider(%{"voice" => nil, "speed" => nil}), %{
               "text" => "hi"
             }) ==
               %{"text" => "hi"}
    end

    test "is idempotent" do
      once = Speech.normalize_request(provider(), %{"text" => "hi"})
      assert Speech.normalize_request(provider(), once) == once
    end
  end

  describe "the request" do
    test "is a POST to <base_url>/audio/speech" do
      serve(&audio/1)
      assert {:ok, _, _} = Speech.call(provider(), nil, request())

      {conn, _body} = sent()
      assert conn.method == "POST"
      assert conn.host == "localhost"
      assert conn.port == 8880
      assert conn.request_path == "/v1/audio/speech"
    end

    test "tolerates a trailing slash on base_url" do
      serve(&audio/1)
      Speech.call(provider(%{"base_url" => "http://localhost:8880/v1/"}), nil, request())

      {conn, _body} = sent()
      assert conn.request_path == "/v1/audio/speech"
    end

    test "carries the model, the text as input, the voice, the speed and the format" do
      serve(&audio/1)
      Speech.call(provider(), nil, request())

      {_conn, body} = sent()

      assert body == %{
               "model" => "kokoro",
               "input" => "Hello there.",
               "voice" => "af_heart",
               "speed" => 1.0,
               "response_format" => "wav"
             }
    end

    test "sends no speed when there is none" do
      serve(&audio/1)
      Speech.call(provider(%{"speed" => nil}), nil, request(provider(%{"speed" => nil})))

      {_conn, body} = sent()
      refute Map.has_key?(body, "speed")
    end

    test "authenticates with a bearer token only when there is a key" do
      serve(&audio/1)

      Speech.call(provider(), "sk-tts-1", request())
      {conn, _} = sent()
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-tts-1"]

      Speech.call(provider(), nil, request())
      {conn, _} = sent()
      assert Plug.Conn.get_req_header(conn, "authorization") == []
    end
  end

  describe "the answer" do
    test "is the audio bytes with the format as extension, and the characters spoken as usage" do
      serve(&audio/1)

      assert Speech.call(provider(), nil, request()) ==
               {:ok, {:binary, @wav, "wav"}, %{cost_usd: 0.0, units: %{"characters" => 12}}}
    end

    test "mp3 is accepted without a WAV check" do
      serve(&audio(&1, "ID3-not-a-wav"))

      assert {:ok, {:binary, "ID3-not-a-wav", "mp3"}, _} =
               Speech.call(provider(%{"format" => "mp3"}), nil, request())

      {_conn, body} = sent()
      assert body["response_format"] == "mp3"
    end

    test "a WAV was asked for and something else came back" do
      serve(&audio(&1, "<html>not audio</html>"))
      assert {:error, {:unexpected_response, message}} = Speech.call(provider(), nil, request())
      assert message =~ "WAV"
    end

    test "an empty reply" do
      serve(&audio(&1, ""))
      assert {:error, {:unexpected_response, _}} = Speech.call(provider(), nil, request())
    end
  end

  describe "failures" do
    test "an HTTP error carries the status and the service's JSON message" do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error": {"message": "voice not found"}}))
      end)

      assert Speech.call(provider(), nil, request()) == {:error, {:http, 500, "voice not found"}}
    end

    test "the API key is redacted if the service echoes it back" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error": "bad key sk-secret-77"})) end)

      assert Speech.call(provider(), "sk-secret-77", request()) ==
               {:error, {:http, 401, "bad key [redacted]"}}
    end

    test "a server that is not running" do
      serve(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert Speech.call(provider(), nil, request()) == {:error, {:transport, :econnrefused}}
    end

    test "bad requests are rejected before anything is sent" do
      assert {:error, {:bad_request, _}} = Speech.call(provider(), nil, %{"voice" => "v"})

      assert {:error, {:bad_request, _}} =
               Speech.call(provider(), nil, request(provider(), %{"text" => "  "}))

      assert {:error, {:bad_request, _}} =
               Speech.call(
                 provider(),
                 nil,
                 request(provider(), %{"text" => String.duplicate("a", 4097)})
               )

      assert {:error, {:bad_request, message}} =
               Speech.call(provider(%{"voice" => nil}), nil, %{"text" => "hi"})

      assert message =~ "voice"
      refute_received {:request, _, _}
    end

    test "provider configuration problems are rejected before anything is sent" do
      assert {:error, {:bad_provider_config, m1}} =
               Speech.call(provider(%{"base_url" => nil}), nil, request())

      assert m1 =~ "base_url"

      assert {:error, {:bad_provider_config, m2}} =
               Speech.call(provider(%{"model" => ""}), nil, request())

      assert m2 =~ "model"

      assert {:error, {:bad_provider_config, m3}} =
               Speech.call(provider(%{"format" => "ogg"}), nil, request())

      assert m3 =~ "format"
      refute_received {:request, _, _}
    end
  end
end
