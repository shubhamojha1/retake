defmodule Retake.Pipeline.ScriptTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Script
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage.Local

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "llm", fallbacks = [] }
  tts = { use = "t", fallbacks = [] }
  stt = { use = "s", fallbacks = [] }
  stock = { use = "k", fallbacks = [] }
  music = { use = "m", fallbacks = [] }

  [providers.llm]
  capability = "llm"
  adapter = "fake"
  model = "m"

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

  # 12 words a scene, 3 scenes: 36 words, close to the 38 a 15 second video wants.
  @brief %{
    prompt: "Why tea is good for you",
    target_duration_ms: 15_000,
    tone: "friendly",
    audience: "adults"
  }

  setup %{tmp_dir: dir} do
    {:ok, config} = Config.parse(@config)

    client =
      Client.new(
        config: config,
        profile: "dev",
        storage: Local.new(Path.join(dir, "store")),
        cache_root: Path.join(dir, "cache"),
        usage: start_supervised!(Usage)
      )

    %{client: client, dir: dir}
  end

  # --- helpers ---------------------------------------------------------------------

  defp scene(i, extra \\ %{}) do
    Map.merge(
      %{
        "narration" => "Scene #{i} narration with a handful of words to speak out loud.",
        "visual_query" => "tea pouring cup"
      },
      extra
    )
  end

  defp script_json(scenes \\ nil, title \\ "Tea facts") do
    Jason.encode!(%{"title" => title, "scenes" => scenes || for(i <- 1..3, do: scene(i))})
  end

  defp reply(text, finish \\ "stop"),
    do: {:ok, {:json, %{"content" => text, "finish_reason" => finish}}, %{}}

  # The model's replies, one per call.
  defp replies(list) do
    Process.put(:replies, list)

    Process.put(:fake_adapter_answers, %{
      "llm" => fn _request ->
        [next | rest] = Process.get(:replies)
        Process.put(:replies, rest)
        next
      end
    })
  end

  defp requests do
    receive do
      {:adapter_called, "llm", _key, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  defp last_user_message(request), do: request["messages"] |> List.last() |> Map.fetch!("content")

  # --- the happy path -----------------------------------------------------------------

  describe "generate/3" do
    test "returns the title and the scenes", %{client: client} do
      replies([reply(script_json())])

      assert {:ok, %{title: "Tea facts", scenes: scenes}} = Script.generate(client, @brief)
      assert length(scenes) == 3

      assert %{
               narration: "Scene 1 narration with a handful of words to speak out loud.",
               visual_query: "tea pouring cup",
               on_screen_text: nil
             } = hd(scenes)
    end

    test "keeps on_screen_text when given, and drops it when blank", %{client: client} do
      scenes = [
        scene(1, %{"on_screen_text" => " Tea time "}),
        scene(2, %{"on_screen_text" => "   "}),
        scene(3)
      ]

      replies([reply(script_json(scenes))])

      {:ok, %{scenes: [first, second, third]}} = Script.generate(client, @brief)
      assert first.on_screen_text == "Tea time"
      assert second.on_screen_text == nil
      assert third.on_screen_text == nil
    end

    test "keeps image_prompt when given, and makes it nil when blank or missing", %{
      client: client
    } do
      scenes = [
        scene(1, %{"image_prompt" => " A dim room, a phone glowing on a pillow. "}),
        scene(2, %{"image_prompt" => "   "}),
        scene(3)
      ]

      replies([reply(script_json(scenes))])

      assert {:ok, %{scenes: [first, second, third]}} = Script.generate(client, @brief)
      assert first.image_prompt == "A dim room, a phone glowing on a pillow."
      assert second.image_prompt == nil
      assert third.image_prompt == nil
    end

    test "an image_prompt over 450 characters is rejected and the reply retried", %{
      client: client
    } do
      too_long = [scene(1, %{"image_prompt" => String.duplicate("a", 451)}), scene(2), scene(3)]
      replies([reply(script_json(too_long)), reply(script_json())])

      assert {:ok, %{scenes: scenes}} = Script.generate(client, @brief)
      assert length(scenes) == 3
      assert length(requests()) == 2
    end

    test "the prompt asks for an image_prompt in every scene, kept to the middle of the picture",
         %{
           client: client
         } do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      system = request["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ ~s("image_prompt")
      assert system =~ "vertical composition"
      assert system =~ "middle half"
    end

    test "one style for the whole video is added to every image prompt", %{client: client} do
      scenes = [
        scene(1, %{"image_prompt" => "A dim room."}),
        scene(2, %{"image_prompt" => "A glowing brain."}),
        scene(3)
      ]

      json =
        Jason.encode!(%{
          "title" => "Tea facts",
          "style" => " soft watercolor, warm palette ",
          "scenes" => scenes
        })

      replies([reply(json)])

      assert {:ok, %{style: "soft watercolor, warm palette", scenes: [first, second, third]}} =
               Script.generate(client, @brief)

      assert first.image_prompt == "A dim room. Style: soft watercolor, warm palette"
      assert second.image_prompt == "A glowing brain. Style: soft watercolor, warm palette"
      assert third.image_prompt == nil
    end

    test "a blank or missing style leaves the image prompts as they are", %{client: client} do
      scenes = [scene(1, %{"image_prompt" => "A dim room."}), scene(2), scene(3)]

      for style <- [%{"style" => "   "}, %{}] do
        json = Jason.encode!(Map.merge(%{"title" => "Tea facts", "scenes" => scenes}, style))
        replies([reply(json)])

        assert {:ok, %{style: nil, scenes: [first | _]}} = Script.generate(client, @brief)
        assert first.image_prompt == "A dim room."
      end
    end

    test "a style over 120 characters is rejected and the reply retried", %{client: client} do
      bad =
        Jason.encode!(%{
          "title" => "Tea facts",
          "style" => String.duplicate("s", 121),
          "scenes" => [scene(1), scene(2), scene(3)]
        })

      replies([reply(bad), reply(script_json())])

      assert {:ok, _} = Script.generate(client, @brief)
      assert length(requests()) == 2
    end

    test "the longest prompt and style still fit the spec's 600 characters", %{client: client} do
      json =
        Jason.encode!(%{
          "title" => "Tea facts",
          "style" => String.duplicate("s", 120),
          "scenes" => [
            scene(1, %{"image_prompt" => String.duplicate("a", 450)}),
            scene(2),
            scene(3)
          ]
        })

      replies([reply(json)])

      assert {:ok, %{scenes: [first | _]}} = Script.generate(client, @brief)
      assert String.length(first.image_prompt) <= 600
    end

    test "the prompt asks for a clearly lit subject, even at night", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      system = request["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ "clearly lit"
    end

    test "the prompt asks for scenes a camera could film, not symbols", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      system = request["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ "a camera could film"
      assert system =~ "not through symbols"
    end

    test "the prompt keeps the medium out of the image prompts, because the style sets it", %{
      client: client
    } do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      system = request["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ "the style sets the medium"
    end

    test "the prompt asks for one style for the whole video", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      system = request["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ ~s("style")
      assert system =~ "the same style"
    end

    test "trims whitespace around every field", %{client: client} do
      scenes = [scene(1, %{"narration" => "  Hello there.  ", "visual_query" => " a cup "})]
      replies([reply(script_json(scenes, "  A title  "))])

      {:ok, %{title: "A title", scenes: [%{narration: "Hello there.", visual_query: "a cup"}]}} =
        Script.generate(client, @brief)
    end

    test "asks the LLM for JSON against the schema", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      assert request["response_schema"]["name"] == "video_script"
      assert request["response_schema"]["schema"]["required"] == ["title", "scenes"]
    end

    test "puts the topic, tone and audience in the user message", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [%{"messages" => [system, user]}] = requests()
      assert system["role"] == "system"
      assert user["role"] == "user"
      assert user["content"] == "Topic: Why tea is good for you\nTone: friendly\nAudience: adults"
    end

    test "omits tone and audience when not given", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, %{prompt: "Tea"})

      [request] = requests()
      assert last_user_message(request) == "Topic: Tea"
    end

    test "tells the model the format, the language and how much to write", %{client: client} do
      replies([reply(script_json())])

      {:ok, _} =
        Script.generate(client, %{prompt: "Tea", target_duration_ms: 30_000, language: "pt-BR"})

      [%{"messages" => [%{"content" => system}, _user]}] = requests()
      assert system =~ "ONLY a JSON object"
      assert system =~ ~s("pt-BR")
      assert system =~ "about 5 scenes"
      assert system =~ "75 words"
      assert system =~ "30 seconds"
    end

    test "asks for scenes of about the same length, so the pacing is even", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, %{prompt: "Tea", target_duration_ms: 30_000})

      [%{"messages" => [%{"content" => system}, _user]}] = requests()
      # 75 words over 5 scenes: 15 a scene
      assert system =~ "about 15 words"
      assert system =~ "about the same time"
    end
  end

  describe "tolerant parsing" do
    test "a markdown fence around the JSON", %{client: client} do
      replies([reply("```json\n" <> script_json() <> "\n```")])
      assert {:ok, %{title: "Tea facts"}} = Script.generate(client, @brief)
    end

    test "a line of chatter before and after", %{client: client} do
      replies([reply("Here is your script:\n" <> script_json() <> "\nHope that helps!")])
      assert {:ok, %{title: "Tea facts"}} = Script.generate(client, @brief)
    end
  end

  describe "retrying a bad reply" do
    test "invalid JSON: asks again with the problem spelled out", %{client: client} do
      replies([reply("this is not json at all"), reply(script_json())])

      assert {:ok, %{title: "Tea facts"}} = Script.generate(client, @brief)

      [first, second] = requests()
      assert length(first["messages"]) == 2
      assert length(second["messages"]) == 3
      assert last_user_message(second) =~ "rejected"
      assert last_user_message(second) =~ "not valid JSON"
      assert last_user_message(second) =~ "ONLY the corrected JSON"
    end

    test "a schema violation names the field", %{client: client} do
      broken = Jason.encode!(%{"title" => "T", "scenes" => [%{"narration" => "Hello"}]})
      replies([reply(broken), reply(script_json())])

      assert {:ok, _} = Script.generate(client, @brief)

      [_first, second] = requests()
      assert last_user_message(second) =~ "visual_query"
    end

    test "a blank narration is rejected", %{client: client} do
      blank = script_json([scene(1, %{"narration" => "   "})])
      replies([reply(blank), reply(script_json())])

      assert {:ok, _} = Script.generate(client, @brief)

      [_first, second] = requests()
      assert last_user_message(second) =~ "/scenes/0"
      assert last_user_message(second) =~ "narration"
    end

    test "too many scenes is rejected", %{client: client} do
      too_many = script_json(for(i <- 1..41, do: scene(i)))
      replies([reply(too_many), reply(script_json())])

      assert {:ok, %{scenes: scenes}} = Script.generate(client, @brief)
      assert length(scenes) == 3
    end

    test "a reply cut off for length says so", %{client: client} do
      replies([reply(~s({"title": "T", "scenes": [{"narra), "length"), reply(script_json())])

      assert {:ok, _} = Script.generate(client, @brief)

      [_first, second] = requests()
      assert last_user_message(second) =~ "cut off"
    end

    test "gives up after max_attempts and reports what was wrong", %{client: client, dir: dir} do
      replies([reply("nope 1"), reply("nope 2"), reply("nope 3")])

      assert {:error, {:script_invalid, %{attempts: 3, errors: errors}}} =
               Script.generate(client, @brief)

      assert Enum.any?(errors, &(&1 =~ "not valid JSON"))
      assert length(requests()) == 3
      assert Path.wildcard(Path.join(dir, "cache/*.json")) == []
    end

    test "max_attempts: 1 does not retry", %{client: client} do
      replies([reply("nope")])

      assert {:error, {:script_invalid, %{attempts: 1}}} =
               Script.generate(client, @brief, max_attempts: 1)

      assert length(requests()) == 1
    end

    test "a bad reply is never cached, only the good one", %{client: client, dir: dir} do
      replies([reply("nope"), reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      assert length(Path.wildcard(Path.join(dir, "cache/*.json"))) == 1
    end

    test "a provider failure is not the model's fault: no retry", %{client: client} do
      Process.put(:fake_adapter_answers, %{"llm" => {:error, {:transport, :timeout}}})

      assert {:error,
              {:all_providers_failed, [%{provider: "llm", reason: {:transport, :timeout}}]}} =
               Script.generate(client, @brief)

      assert length(requests()) == 1
    end
  end

  describe "caching" do
    test "the same brief is answered from the cache the second time", %{client: client} do
      replies([reply(script_json())])

      {:ok, first} = Script.generate(client, @brief)
      assert first.cached == false
      assert length(requests()) == 1

      assert {:ok, second} = Script.generate(client, @brief)
      assert second.cached == true
      assert Map.delete(second, :cached) == Map.delete(first, :cached)
      assert requests() == []
    end
  end

  describe "warnings" do
    test "none when the script fits the target", %{client: client} do
      replies([reply(script_json())])
      assert {:ok, %{warnings: []}} = Script.generate(client, @brief)
    end

    test "a script far too short for the target is flagged, not rejected", %{client: client} do
      replies([reply(script_json())])

      assert {:ok, %{warnings: [warning]}} =
               Script.generate(client, %{@brief | target_duration_ms: 60_000})

      assert warning =~ "36 words"
      assert warning =~ "60 second"
    end
  end

  describe "the brief" do
    test "a blank prompt is rejected before anything is asked", %{client: client} do
      assert {:error, {:invalid_brief, [message]}} = Script.generate(client, %{prompt: "  "})
      assert message =~ "prompt"
      assert requests() == []
    end

    test "a missing prompt is rejected", %{client: client} do
      assert {:error, {:invalid_brief, [message]}} = Script.generate(client, %{})
      assert message =~ "prompt"
    end

    test "the target duration must be in the spec's range", %{client: client} do
      assert {:error, {:invalid_brief, [message]}} =
               Script.generate(client, %{prompt: "Tea", target_duration_ms: 1_000})

      assert message =~ "target_duration_ms"
    end

    test "the language must look like a language code", %{client: client} do
      assert {:error, {:invalid_brief, [message]}} =
               Script.generate(client, %{prompt: "Tea", language: "English"})

      assert message =~ "language"
    end

    test "reports every problem at once", %{client: client} do
      assert {:error, {:invalid_brief, messages}} =
               Script.generate(client, %{prompt: "", target_duration_ms: 1, language: "x"})

      assert length(messages) == 3
    end
  end
end
