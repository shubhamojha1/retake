defmodule Retake.Providers.Adapters.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Adapters.OpenAICompatible
  alias Retake.Providers.{Client, Config, Provider}
  alias Retake.Storage.Local

  @stub OpenAICompatible

  @request %{
    "messages" => [
      %{"role" => "system", "content" => "You write scripts."},
      %{"role" => "user", "content" => "A video about tea."}
    ]
  }

  @schema %{"type" => "object", "properties" => %{"title" => %{"type" => "string"}}}

  @completion %{
    "choices" => [
      %{
        "message" => %{"role" => "assistant", "content" => ~s({"title":"Tea"})},
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 5, "total_tokens" => 17}
  }

  defp provider(options \\ %{}) do
    %Provider{
      name: "groq",
      capability: :llm,
      adapter: "openai_compatible",
      api_key_env: "GROQ_API_KEY",
      options:
        Map.merge(
          %{
            "base_url" => "https://api.groq.com/openai/v1",
            "model" => "openai/gpt-oss-120b",
            "structured_output" => "json_schema",
            "temperature" => 0.4,
            "timeout_ms" => 5_000
          },
          options
        )
    }
  end

  # Stubs the server: the test process is sent the request as the server saw it.
  defp serve(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, Jason.decode!(raw)})
      reply.(conn)
    end)
  end

  defp ok(conn, body \\ @completion), do: Req.Test.json(conn, body)

  defp sent do
    assert_received {:request, conn, body}
    {conn, body}
  end

  describe "the request" do
    test "is a POST to <base_url>/chat/completions" do
      serve(&ok/1)
      assert {:ok, _, _} = OpenAICompatible.call(provider(), "key", @request)

      {conn, _body} = sent()
      assert conn.method == "POST"
      assert conn.host == "api.groq.com"
      assert conn.request_path == "/openai/v1/chat/completions"
    end

    test "tolerates a trailing slash on base_url" do
      serve(&ok/1)

      OpenAICompatible.call(
        provider(%{"base_url" => "http://localhost:11434/v1/"}),
        nil,
        @request
      )

      {conn, _body} = sent()
      assert conn.request_path == "/v1/chat/completions"
    end

    test "authenticates with the key as a bearer token" do
      serve(&ok/1)
      OpenAICompatible.call(provider(), "gsk-123", @request)

      {conn, _body} = sent()
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer gsk-123"]
    end

    test "sends no authorization header when the provider needs no key" do
      serve(&ok/1)
      OpenAICompatible.call(provider(), nil, @request)

      {conn, _body} = sent()
      assert Plug.Conn.get_req_header(conn, "authorization") == []
    end

    test "carries the model, messages and temperature" do
      serve(&ok/1)
      OpenAICompatible.call(provider(), "key", @request)

      {_conn, body} = sent()
      assert body["model"] == "openai/gpt-oss-120b"
      assert body["messages"] == @request["messages"]
      assert body["temperature"] == 0.4
    end

    test "omits options the provider does not set" do
      serve(&ok/1)
      OpenAICompatible.call(provider(%{"temperature" => nil}), "key", @request)

      {_conn, body} = sent()
      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "max_tokens")
    end

    test "json_schema mode sends the schema as response_format" do
      serve(&ok/1)
      request = Map.put(@request, "response_schema", %{"name" => "script", "schema" => @schema})
      OpenAICompatible.call(provider(), "key", request)

      {_conn, body} = sent()

      assert body["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{"name" => "script", "schema" => @schema}
             }
    end

    test "json_object mode asks for a JSON object" do
      serve(&ok/1)
      request = Map.put(@request, "response_schema", %{"name" => "script", "schema" => @schema})
      OpenAICompatible.call(provider(%{"structured_output" => "json_object"}), "key", request)

      {_conn, body} = sent()
      assert body["response_format"] == %{"type" => "json_object"}
    end

    test "sends no response_format when the request wants no schema" do
      serve(&ok/1)
      OpenAICompatible.call(provider(), "key", @request)

      {_conn, body} = sent()
      refute Map.has_key?(body, "response_format")
    end

    test "sends no response_format when the provider has no structured output" do
      serve(&ok/1)
      request = Map.put(@request, "response_schema", %{"name" => "script", "schema" => @schema})
      OpenAICompatible.call(provider(%{"structured_output" => nil}), "key", request)

      {_conn, body} = sent()
      refute Map.has_key?(body, "response_format")
    end
  end

  describe "the answer" do
    test "is the reply text and finish reason, with token counts as usage" do
      serve(&ok/1)

      assert OpenAICompatible.call(provider(), "key", @request) ==
               {:ok, {:json, %{"content" => ~s({"title":"Tea"}), "finish_reason" => "stop"}},
                %{cost_usd: 0.0, units: %{"prompt_tokens" => 12, "completion_tokens" => 5}}}
    end

    test "works without a usage block" do
      serve(fn conn -> ok(conn, Map.delete(@completion, "usage")) end)
      assert {:ok, _, %{units: %{}}} = OpenAICompatible.call(provider(), "key", @request)
    end

    test "a body that is not a completion is an unexpected response" do
      serve(fn conn -> ok(conn, %{"hello" => "world"}) end)

      assert {:error, {:unexpected_response, _}} =
               OpenAICompatible.call(provider(), "key", @request)
    end

    test "a reply with no text is an unexpected response" do
      body = %{"choices" => [%{"message" => %{"content" => nil}, "finish_reason" => "length"}]}
      serve(fn conn -> ok(conn, body) end)

      assert {:error, {:unexpected_response, _}} =
               OpenAICompatible.call(provider(), "key", @request)
    end
  end

  describe "failures" do
    test "an HTTP error carries the status and the service's message" do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "Rate limit reached"}})
      end)

      assert OpenAICompatible.call(provider(), "key", @request) ==
               {:error, {:http, 429, "Rate limit reached"}}
    end

    test "a non-JSON error body is kept (truncated)" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 500, String.duplicate("x", 1_000)) end)

      assert {:error, {:http, 500, message}} = OpenAICompatible.call(provider(), "key", @request)
      assert String.length(message) == 300
    end

    test "the API key is redacted if the service echoes it back" do
      serve(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{
          "error" => %{"message" => "Incorrect API key provided: gsk-secret-123."}
        })
      end)

      result = OpenAICompatible.call(provider(), "gsk-secret-123", @request)
      assert result == {:error, {:http, 401, "Incorrect API key provided: [redacted]."}}
    end

    test "a transport failure is reported as such" do
      serve(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert OpenAICompatible.call(provider(), "key", @request) ==
               {:error, {:transport, :timeout}}

      serve(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert OpenAICompatible.call(provider(), "key", @request) ==
               {:error, {:transport, :econnrefused}}
    end

    test "a provider without base_url or model is a configuration error, before any request" do
      assert {:error, {:bad_provider_config, message}} =
               OpenAICompatible.call(provider(%{"base_url" => nil}), "key", @request)

      assert message =~ "base_url"

      assert {:error, {:bad_provider_config, message}} =
               OpenAICompatible.call(provider(%{"model" => ""}), "key", @request)

      assert message =~ "model"
      refute_received {:request, _, _}
    end
  end

  describe "through the Client" do
    @describetag :tmp_dir

    @toml """
    [retake]
    default_profile = "dev"

    [profiles.dev]
    llm = { use = "groq", fallbacks = [] }
    tts = { use = "t", fallbacks = [] }
    stt = { use = "s", fallbacks = [] }
    stock = { use = "k", fallbacks = [] }
    music = { use = "m", fallbacks = [] }

    [providers.groq]
    capability = "llm"
    adapter = "openai_compatible"
    api_key_env = "GROQ_API_KEY"
    base_url = "https://api.groq.com/openai/v1"
    model = "openai/gpt-oss-120b"
    structured_output = "json_schema"

    [providers.t]
    capability = "tts"
    adapter = "fake"

    [providers.s]
    capability = "stt"
    adapter = "fake"

    [providers.k]
    capability = "stock"
    adapter = "fake"

    [providers.m]
    capability = "music"
    adapter = "fake"
    """

    test "the adapter is registered by name, and a repeated request never reaches the server again",
         %{
           tmp_dir: dir
         } do
      {:ok, config} = Config.parse(@toml)

      client =
        Client.new(
          config: config,
          profile: "dev",
          storage: Local.new(Path.join(dir, "store")),
          cache_root: Path.join(dir, "cache"),
          env: %{"GROQ_API_KEY" => "gsk-1"},
          usage: start_supervised!(Retake.Providers.Usage)
        )

      # exactly one request is allowed: a second one would raise and fail the test
      test = self()

      Req.Test.expect(@stub, fn conn ->
        send(test, :served)
        ok(conn)
      end)

      assert {:ok, entry, :miss} = Client.call(client, :llm, @request)
      assert entry.provider == "groq"
      assert entry.model == "openai/gpt-oss-120b"

      assert entry.result ==
               {:json, %{"content" => ~s({"title":"Tea"}), "finish_reason" => "stop"}}

      assert entry.cost.units == %{"prompt_tokens" => 12, "completion_tokens" => 5}
      assert_received :served

      assert {:ok, ^entry, :hit} = Client.call(client, :llm, @request)
      refute_received :served
    end
  end
end
