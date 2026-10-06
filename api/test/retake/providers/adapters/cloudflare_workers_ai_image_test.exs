defmodule Retake.Providers.Adapters.CloudflareWorkersAIImageTest do
  use ExUnit.Case, async: true

  alias Retake.Providers.Adapters
  alias Retake.Providers.Adapters.CloudflareWorkersAIImage, as: Flux
  alias Retake.Providers.Provider
  alias Retake.Test.Images

  @stub Flux
  @account_var "RETAKE_TEST_CF_ACCOUNT"
  @token "tok-secret-123"

  setup_all do
    System.put_env(@account_var, "acc123")
    on_exit(fn -> System.delete_env(@account_var) end)
  end

  defp provider(options \\ %{}) do
    %Provider{
      name: "cloudflare-flux",
      capability: :image,
      adapter: "cloudflare_workers_ai_image",
      api_key_env: "CLOUDFLARE_API_TOKEN",
      options:
        Map.merge(
          %{"model" => "@cf/black-forest-labs/flux-1-schnell", "account_id_env" => @account_var},
          options
        )
    }
  end

  defp request(extra \\ %{}) do
    Flux.normalize_request(provider(), Map.merge(%{"prompt" => "A calm sea at sunrise."}, extra))
  end

  defp serve(reply) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, decode(conn, raw)})
      reply.(conn)
    end)
  end

  # JSON bodies arrive decoded; a multipart form arrives as the raw text.
  defp decode(conn, raw) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      ["application/json" <> _] -> Jason.decode!(raw)
      _other -> raw
    end
  end

  defp sent do
    assert_received {:request, conn, body}
    {conn, body}
  end

  defp image_reply(bytes \\ Images.jpeg(1024, 1024)) do
    fn conn ->
      Req.Test.json(conn, %{"result" => %{"image" => Base.encode64(bytes)}, "success" => true})
    end
  end

  defp failure(status, message) do
    fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"success" => false, "errors" => [%{"code" => 1, "message" => message}]})
    end
  end

  test "the adapter is registered as cloudflare_workers_ai_image" do
    assert Adapters.fetch("cloudflare_workers_ai_image") == {:ok, Flux}
  end

  describe "normalize_request/2" do
    test "fills in steps (default 4) so they are part of the cache key" do
      assert Flux.normalize_request(provider(), %{"prompt" => "p"}) ==
               %{"prompt" => "p", "steps" => 4}
    end

    test "uses the provider's steps setting, and the request's own value wins" do
      assert Flux.normalize_request(provider(%{"steps" => 6}), %{"prompt" => "p"})["steps"] == 6

      assert Flux.normalize_request(provider(%{"steps" => 6}), %{"prompt" => "p", "steps" => 2})[
               "steps"
             ] == 2
    end

    test "is idempotent" do
      once = Flux.normalize_request(provider(), %{"prompt" => "p"})
      assert Flux.normalize_request(provider(), once) == once
    end
  end

  describe "the request" do
    test "is a POST to the account's model endpoint with the token as a bearer" do
      serve(image_reply())
      assert {:ok, _, _} = Flux.call(provider(), @token, request())

      {conn, body} = sent()
      assert conn.method == "POST"
      assert conn.request_path =~ "/accounts/acc123/ai/run/"
      assert String.ends_with?(conn.request_path, "flux-1-schnell")
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
      assert body == %{"prompt" => "A calm sea at sunrise.", "steps" => 4}
    end

    test "uses base_url when the provider sets one" do
      serve(image_reply())

      assert {:ok, _, _} =
               Flux.call(provider(%{"base_url" => "https://cf.test/v9/"}), @token, request())

      {conn, _body} = sent()
      assert conn.host == "cf.test"
      assert String.starts_with?(conn.request_path, "/v9/accounts/acc123/")
    end
  end

  describe "the answer" do
    test "is the decoded JPEG, with no cost and the steps as usage" do
      bytes = Images.jpeg(1024, 1024)
      serve(image_reply(bytes))

      assert {:ok, {:binary, ^bytes, "jpg"}, %{cost_usd: cost, units: %{"steps" => 4}}} =
               Flux.call(provider(), @token, request())

      assert cost == 0.0
    end

    test "accepts a bare {\"image\": ...} reply too" do
      bytes = Images.jpeg(768, 1344)
      serve(fn conn -> Req.Test.json(conn, %{"image" => Base.encode64(bytes)}) end)
      assert {:ok, {:binary, ^bytes, "jpg"}, _} = Flux.call(provider(), @token, request())
    end

    test "a PNG is stored as png" do
      bytes = Images.png(1024, 1024)
      serve(image_reply(bytes))
      assert {:ok, {:binary, ^bytes, "png"}, _} = Flux.call(provider(), @token, request())
    end

    test "reports the steps it was asked for" do
      serve(image_reply())

      assert {:ok, _, %{units: %{"steps" => 8}}} =
               Flux.call(provider(), @token, request(%{"steps" => 8}))
    end
  end

  describe "errors" do
    test "an HTTP error carries Cloudflare's message" do
      serve(failure(429, "daily allowance used up"))

      assert {:error, {:http, 429, "daily allowance used up"}} =
               Flux.call(provider(), @token, request())
    end

    test "the token never appears in an error" do
      serve(failure(400, "bad request near #{@token}"))
      assert {:error, {:http, 400, message}} = Flux.call(provider(), @token, request())
      refute message =~ @token
      assert message =~ "[redacted]"
    end

    test "an error body without Cloudflare's shape is still an error" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 502, "<html>bad gateway</html>") end)

      assert {:error, {:http, 502, "<html>bad gateway</html>"}} =
               Flux.call(provider(), @token, request())
    end

    test "a transport failure" do
      serve(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, {:transport, :timeout}} = Flux.call(provider(), @token, request())
    end

    test "a 200 with no image" do
      serve(fn conn -> Req.Test.json(conn, %{"success" => true, "result" => %{}}) end)

      assert {:error, {:unexpected_response, "the reply had no image"}} =
               Flux.call(provider(), @token, request())
    end

    test "a 200 whose image is not base64" do
      serve(fn conn -> Req.Test.json(conn, %{"result" => %{"image" => "!!! not base64 !!!"}}) end)
      assert {:error, {:unexpected_response, message}} = Flux.call(provider(), @token, request())
      assert message =~ "base64"
    end

    test "a 200 whose bytes are not an image" do
      serve(image_reply("<html>please log in</html>"))
      assert {:error, {:unexpected_response, message}} = Flux.call(provider(), @token, request())
      assert message =~ "not a readable image"
    end

    test "a 200 with a body that is not JSON at all" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
      assert {:error, {:unexpected_response, _}} = Flux.call(provider(), @token, request())
    end
  end

  describe "a portrait size (FLUX.2 models take a multipart form with a size)" do
    defp portrait(options \\ %{}) do
      provider(Map.merge(%{"width" => 768, "height" => 1344}, options))
    end

    test "normalize_request/2 fills in the size from the provider, and no steps" do
      assert Flux.normalize_request(portrait(), %{"prompt" => "p"}) ==
               %{"prompt" => "p", "width" => 768, "height" => 1344}
    end

    test "the request's own size wins, and normalizing twice changes nothing" do
      once =
        Flux.normalize_request(portrait(), %{"prompt" => "p", "width" => 512, "height" => 896})

      assert once == %{"prompt" => "p", "width" => 512, "height" => 896}
      assert Flux.normalize_request(portrait(), once) == once
    end

    test "is a multipart form with the prompt and the size, and no steps" do
      serve(image_reply(Images.jpeg(768, 1344)))
      p = portrait()

      assert {:ok, _, _} =
               Flux.call(p, @token, Flux.normalize_request(p, %{"prompt" => "A calm sea."}))

      {conn, raw} = sent()
      assert conn.method == "POST"
      assert ["multipart/form-data" <> _] = Plug.Conn.get_req_header(conn, "content-type")
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
      assert raw =~ ~r/name="prompt"\r\n\r\nA calm sea\.\r\n/
      assert raw =~ ~r/name="width"\r\n\r\n768\r\n/
      assert raw =~ ~r/name="height"\r\n\r\n1344\r\n/
      refute raw =~ "steps"
    end

    test "returns the picture, with the size as usage" do
      bytes = Images.jpeg(768, 1344)
      serve(image_reply(bytes))
      p = portrait()

      assert {:ok, {:binary, ^bytes, "jpg"},
              %{cost_usd: cost, units: %{"width" => 768, "height" => 1344}}} =
               Flux.call(p, @token, Flux.normalize_request(p, %{"prompt" => "p"}))

      assert cost == 0.0
    end

    test "a size outside 256 to 2048 is refused" do
      request = %{"prompt" => "p", "width" => 100, "height" => 1344}
      assert {:error, {:bad_request, message}} = Flux.call(provider(), @token, request)
      assert message =~ "256 to 2048"
    end

    test "a width without a height is refused" do
      request = %{"prompt" => "p", "width" => 768}
      assert {:error, {:bad_request, message}} = Flux.call(provider(), @token, request)
      assert message =~ "width and height"
    end
  end

  describe "bad settings and bad requests" do
    test "no token" do
      assert {:error, {:bad_provider_config, message}} = Flux.call(provider(), nil, request())
      assert message =~ "api_key_env"
    end

    test "no model" do
      options = Map.delete(provider().options, "model")

      assert {:error, {:bad_provider_config, message}} =
               Flux.call(%{provider() | options: options}, @token, request())

      assert message =~ "model"
    end

    test "no account id in the environment" do
      p = provider(%{"account_id_env" => "RETAKE_TEST_CF_ACCOUNT_NOT_SET"})
      assert {:error, {:bad_provider_config, message}} = Flux.call(p, @token, request())
      assert message =~ "RETAKE_TEST_CF_ACCOUNT_NOT_SET"
    end

    test "a blank prompt" do
      assert {:error, {:bad_request, "prompt must not be blank"}} =
               Flux.call(provider(), @token, request(%{"prompt" => "   "}))
    end

    test "a prompt over Cloudflare's 2048 characters" do
      long = String.duplicate("a", 2049)

      assert {:error, {:bad_request, message}} =
               Flux.call(provider(), @token, request(%{"prompt" => long}))

      assert message =~ "2048"
    end

    test "no prompt" do
      assert {:error, {:bad_request, "the request needs a prompt"}} =
               Flux.call(provider(), @token, %{"steps" => 4})
    end

    test "steps outside 1 to 8" do
      assert {:error, {:bad_request, message}} =
               Flux.call(provider(), @token, request(%{"steps" => 9}))

      assert message =~ "1 to 8"
      assert {:error, {:bad_request, _}} = Flux.call(provider(), @token, request(%{"steps" => 0}))
    end
  end
end
