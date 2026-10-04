defmodule Retake.Pipeline.Script do
  @moduledoc """
  Step 1 of the pipeline: a brief becomes a title and a list of scenes, each with
  the narration to speak, a stock-search phrase for the visual, and optional
  on-screen text. These fill `title` and `scenes[].intent` in the spec.

  The LLM is asked for JSON against a schema (providers with structured output
  enforce it). Whatever comes back is parsed leniently (a markdown fence or a line
  of chatter around the JSON is tolerated), checked against the schema, and cleaned
  up. A reply that fails is never cached (`Retake.Providers.Client` validates before
  it stores) and the model is asked again with the errors spelled out, up to
  `:max_attempts` times (default 3).

  This module only talks to providers through `Retake.Providers.Client`.
  """

  alias Retake.Providers.Client

  @max_attempts 3
  @seconds_per_scene 6
  @words_per_second 2.5
  @excerpt 200

  @brief_defaults %{target_duration_ms: 45_000, language: "en", tone: nil, audience: nil}

  # Mirrors the limits of `scenes[].intent` and `title` in spec/video.schema.json.
  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["title", "scenes"],
    "properties" => %{
      "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
      "scenes" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 40,
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["narration", "visual_query"],
          "properties" => %{
            "narration" => %{"type" => "string", "minLength" => 1, "maxLength" => 1000},
            "visual_query" => %{"type" => "string", "minLength" => 1, "maxLength" => 300},
            "on_screen_text" => %{"type" => "string", "maxLength" => 120}
          }
        }
      }
    }
  }
  @root JSV.build!(@schema)

  @type scene :: %{
          narration: String.t(),
          visual_query: String.t(),
          on_screen_text: String.t() | nil
        }
  @type script :: %{
          title: String.t(),
          scenes: [scene()],
          warnings: [String.t()],
          cached: boolean()
        }

  @doc """
  Writes the script for `brief`: `%{prompt: ..}` plus optional `:target_duration_ms`
  (default 45 000), `:language` (default "en"), `:tone`, `:audience`.

  Returns `{:ok, script}`, `{:error, {:invalid_brief, reasons}}`,
  `{:error, {:script_invalid, %{attempts: n, errors: reasons}}}` when the model never
  produced a usable reply, or the provider error from `Retake.Providers.Client`.
  `warnings` lists soft problems (for example a script far too short for the target);
  `cached` is true when the reply came from the request cache, not a provider.
  """
  @spec generate(Client.t(), map(), keyword()) :: {:ok, script()} | {:error, term()}
  def generate(%Client{} = client, brief, opts \\ []) do
    with {:ok, brief} <- check_brief(brief) do
      max = Keyword.get(opts, :max_attempts, @max_attempts)
      attempt(client, brief, messages(brief), [], 1, max)
    end
  end

  # --- the retry loop ------------------------------------------------------------------

  defp attempt(client, brief, messages, feedback, n, max) do
    request = %{
      "messages" => messages ++ feedback,
      "response_schema" => %{"name" => "video_script", "schema" => @schema}
    }

    case Client.call(client, :llm, request, validate: &validate/1) do
      {:ok, entry, outcome} ->
        finish(entry, brief, outcome)

      {:error, {:all_providers_failed, attempts} = reason} ->
        case rejected_replies(attempts) do
          [] ->
            {:error, reason}

          errors when n < max ->
            attempt(client, brief, messages, [feedback_message(errors)], n + 1, max)

          errors ->
            {:error, {:script_invalid, %{attempts: n, errors: errors}}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The errors of every reply a provider returned but we refused. Failures of other
  # kinds (network, rate limit, missing key) are not the model's fault: no retry.
  defp rejected_replies(attempts) do
    attempts
    |> Enum.flat_map(fn
      %{reason: {:invalid_result, %{errors: errors}}} -> errors
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp feedback_message(errors) do
    list = Enum.map_join(errors, "\n", &"- #{&1}")

    %{
      "role" => "user",
      "content" =>
        "Your previous reply was rejected:\n#{list}\n" <>
          "Reply again with ONLY the corrected JSON object, nothing else."
    }
  end

  defp finish(entry, brief, outcome) do
    {:json, %{"content" => text}} = entry.result

    case parse(text) do
      {:ok, script} ->
        {:ok, Map.merge(script, %{warnings: warnings(script, brief), cached: outcome == :hit})}

      {:error, errors} ->
        {:error, {:script_invalid, %{attempts: 1, errors: errors}}}
    end
  end

  # --- validating a reply ----------------------------------------------------------------

  # Used by the Client on every fresh reply, before it is stored.
  defp validate({:json, %{"content" => text} = reply}) do
    case parse(text) do
      {:ok, _script} ->
        :ok

      {:error, errors} ->
        errors =
          if reply["finish_reason"] == "length",
            do: [
              "the reply was cut off because it was too long: write shorter narration" | errors
            ],
            else: errors

        {:error, %{errors: errors, excerpt: String.slice(text, 0, @excerpt)}}
    end
  end

  defp validate(_other), do: {:error, %{errors: ["the reply had no text"], excerpt: ""}}

  @spec parse(String.t()) ::
          {:ok, %{title: String.t(), scenes: [scene()]}} | {:error, [String.t()]}
  defp parse(text) do
    with {:ok, data} <- decode(text),
         :ok <- check_schema(data),
         {:ok, script} <- clean(data) do
      {:ok, script}
    end
  end

  # Models sometimes wrap JSON in a ```json fence or add a sentence before it.
  defp decode(text) do
    candidates = [String.trim(text), unfence(text), between_braces(text)]

    Enum.find_value(
      candidates,
      {:error, ["the reply is not valid JSON: reply with one JSON object only"]},
      fn candidate ->
        with true <- is_binary(candidate),
             {:ok, %{} = data} <- Jason.decode(candidate) do
          {:ok, data}
        else
          _ -> nil
        end
      end
    )
  end

  defp unfence(text) do
    case Regex.run(~r/```(?:json)?\s*(.*?)\s*```/s, text) do
      [_, inner] -> inner
      nil -> nil
    end
  end

  defp between_braces(text) do
    with [first | _] <- :binary.matches(text, "{"),
         [_ | _] = closes <- :binary.matches(text, "}"),
         {start, _} = first,
         {close, _} = List.last(closes),
         true <- close > start do
      binary_part(text, start, close - start + 1)
    else
      _ -> nil
    end
  end

  defp check_schema(data) do
    case JSV.validate(data, @root, cast: false) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, schema_errors(error)}
    end
  end

  defp schema_errors(error) do
    %{details: units} = JSV.normalize_error(error, min_error_level: 10)

    errors =
      for %{instanceLocation: location, errors: errors} <- units,
          %{message: message} <- errors do
        "#{where(location)}: #{message}"
      end

    if errors == [], do: ["the reply does not match the schema"], else: errors
  end

  defp where("#"), do: "at the top level"
  defp where("#" <> pointer), do: "at #{pointer}"

  # The schema allows blank strings of spaces; a script with them is unusable.
  defp clean(data) do
    scenes = Enum.map(data["scenes"], &clean_scene/1)
    title = String.trim(data["title"])

    errors =
      if(title == "", do: ["/title: must not be blank"], else: []) ++
        for {{:error, message}, index} <- Enum.with_index(scenes),
            do: "/scenes/#{index}: #{message}"

    case errors do
      [] -> {:ok, %{title: title, scenes: Enum.map(scenes, fn {:ok, scene} -> scene end)}}
      errors -> {:error, errors}
    end
  end

  defp clean_scene(scene) do
    narration = String.trim(scene["narration"])
    visual_query = String.trim(scene["visual_query"])

    on_screen_text =
      case scene["on_screen_text"] do
        nil -> nil
        text -> if String.trim(text) == "", do: nil, else: String.trim(text)
      end

    cond do
      narration == "" ->
        {:error, "narration must not be blank"}

      visual_query == "" ->
        {:error, "visual_query must not be blank"}

      true ->
        {:ok, %{narration: narration, visual_query: visual_query, on_screen_text: on_screen_text}}
    end
  end

  # --- soft checks -------------------------------------------------------------------------

  defp warnings(script, brief) do
    words = script.scenes |> Enum.map(&length(String.split(&1.narration))) |> Enum.sum()
    wanted = target_words(brief)

    if words < wanted * 0.6 or words > wanted * 1.4 do
      [
        "the script has #{words} words; about #{wanted} fit a #{div(brief.target_duration_ms, 1000)} second video"
      ]
    else
      []
    end
  end

  defp target_words(brief), do: round(brief.target_duration_ms / 1000 * @words_per_second)

  # --- the brief and the prompt ---------------------------------------------------------------

  defp check_brief(brief) when is_map(brief) do
    brief = @brief_defaults |> Map.put(:prompt, nil) |> Map.merge(brief)

    errors =
      Enum.reject(
        [
          prompt_error(brief.prompt),
          target_error(brief.target_duration_ms),
          language_error(brief.language)
        ],
        &is_nil/1
      )

    if errors == [], do: {:ok, brief}, else: {:error, {:invalid_brief, errors}}
  end

  defp check_brief(_other), do: {:error, {:invalid_brief, ["the brief must be a map"]}}

  defp prompt_error(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" -> "prompt must not be blank"
      String.length(prompt) > 4000 -> "prompt must be at most 4000 characters"
      true -> nil
    end
  end

  defp prompt_error(_other), do: "prompt is required"

  defp target_error(ms) when is_integer(ms) and ms >= 5_000 and ms <= 180_000, do: nil
  defp target_error(_other), do: "target_duration_ms must be between 5000 and 180000"

  defp language_error(language) when is_binary(language) do
    if Regex.match?(~r/\A[a-z]{2}(-[A-Z]{2})?\z/, language), do: nil, else: language_error(nil)
  end

  defp language_error(_other), do: "language must look like \"en\" or \"pt-BR\""

  defp messages(brief) do
    seconds = div(brief.target_duration_ms, 1000)
    scenes = (seconds / @seconds_per_scene) |> round() |> max(3) |> min(12)

    system = """
    You are a scriptwriter for short vertical videos (TikTok, Reels, Shorts). Write the \
    voice-over script and choose the visuals, scene by scene.

    Reply with ONLY a JSON object, no markdown and no commentary, shaped like this:
    {"title": "...", "scenes": [{"narration": "...", "visual_query": "...", "on_screen_text": "..."}]}

    Rules:
    - narration: what the narrator says in this scene. Plain spoken sentences, one to three \
    short ones. No emojis, hashtags or stage directions. Write it in the language "#{brief.language}".
    - visual_query: two to five English words describing a real stock video or photo that fits \
    the scene, for example "phone battery low dark room". Concrete and filmable. No names, brands, \
    text or logos.
    - on_screen_text: optional, a headline of at most six words shown over the scene. Leave it out \
    unless it helps.
    - Open with a hook in the first scene. End with a clear takeaway.
    - Use about #{scenes} scenes and about #{target_words(brief)} words of narration in total, so the \
    video runs about #{seconds} seconds (speech is about #{@words_per_second} words per second).
    """

    details =
      [{"Tone", brief.tone}, {"Audience", brief.audience}]
      |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
      |> Enum.map(fn {label, value} -> "#{label}: #{value}" end)

    user = Enum.join(["Topic: #{String.trim(brief.prompt)}" | details], "\n")

    [
      %{"role" => "system", "content" => String.trim_trailing(system)},
      %{"role" => "user", "content" => user}
    ]
  end
end
