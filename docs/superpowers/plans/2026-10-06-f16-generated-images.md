# F16 Generated Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scene can show an AI-generated image (Cloudflare Workers AI, FLUX.1 schnell) instead of stock footage, falling back to stock whenever an image cannot be made.

**Architecture:** A new optional `image` capability and one provider-specific adapter sit behind `Retake.Providers.Client` and the request cache. The script step also writes an `image_prompt` per scene (a new optional intent field, spec 0.2). A new `Visuals` step replaces the stock step in the pipeline: generated first when the profile has an `image` slot and the scene has a prompt, stock otherwise or on any image failure.

**Tech Stack:** Elixir 1.18 / Phoenix, Req (+ `Req.Test` stubs), JSV, ExUnit; Rust (serde) for the renderer's spec parser; React/TypeScript with `node --test` for the web page.

**Spec:** `docs/superpowers/specs/2026-10-06-f16-generated-images-design.md` (read it first; this plan implements it).

**Deviations from the spec, found while reading the code (small, deliberate):**
- `normalize_request/2` fills only `steps`, not the model: `Retake.Providers.Client` already puts the provider's `model` into the cache key and the asset's provenance.
- The generated asset's licence name is built from the cache entry (`"AI-generated: <model>"`), not hard-coded to Cloudflare, because `Pipeline.Images` is provider-agnostic.
- A missing key is treated like "no image provider": stock is used with no warning (otherwise every user of the `free` profile without Cloudflare keys would see a warning per scene).

## How this repo is worked on (read before starting)

- The repo is `~/projects/retake` in WSL (from Windows: `\\wsl$\Ubuntu\home\shubham\projects\retake`). **The user runs every command** (tests, installs, git) and pastes the output. Steps marked **User runs** are given to the user with the expected output; never claim a pass that was not pasted back.
- **Never commit.** AGENTS rule 12 and the user's rule: give the user the exact `git add` / `git commit` commands at the end of each task; they run them. Before any commit they run `cd api && mix format`. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- `unset MIX_ENV` before `mix test` outside `just test`.
- Plain words and short answers in chat; define terms before using them.

## Global Constraints

- Tests never touch the network (AGENTS rule 6): HTTP adapters talk to `Req.Test` stubs; an unstubbed request raises.
- API keys only from environment variables; never logged, stored, or put in specs, provenance or fixtures (rule 7). The Cloudflare account id is also read from an environment variable named in the config.
- Pipeline code calls providers only through `Retake.Providers.Client` (rules 5, 9). `scripts/check-boundaries.sh` fails if any file under `api/lib/retake/pipeline*` contains the word `Req`, `Retake.Providers.Adapters`, or a concrete storage backend. Keep those words out of pipeline code, comments and docs included.
- A format change updates the schema, `spec/SPEC.md`, examples, fixtures, `spec_version`, and adds a migration for older versions (rule 2): here 0.1 to 0.2.
- The Elixir app links no media library (rule 8): image sizes are read from the bytes in pure Elixir.
- Cloudflare facts used: free allowance 10,000 Neurons a day; FLUX.1 schnell request is JSON `{prompt (1-2048 chars), steps (max 8, default 4)}`; the reply carries a base64 JPEG; the docs list no width or height field. **Unverified until Task 4's real run:** the output size (probably 1024x1024), the exact reply envelope, refusal behaviour.
- Scene `intent` and resolved assets stay separate (rule 4); every asset carries provenance (provider, model, request, request_hash, cost).

## Review Focus

Most likely first. Each line has its test in the named task.

1. Image provider configured but its environment variables are missing: stock is used, silently, for every scene (Task 8, `Visuals` test "no warning when the image provider has no key"; Task 9 pipeline test "no image slot").
2. The service answers 200 with something that is not an image (empty, bad base64, an HTML page): an error, never cached, and the scene falls back to stock (Task 3 adapter tests; Task 7 `Images` test "a reply that is not an image"; Task 8 fallback test).
3. A square image (the likely FLUX.1 output): the asset is still valid, but the scene gets a warning that cover fit crops its sides (Task 7 test "warns when the image is not portrait").
4. A blank or whitespace-only `image_prompt`, or a script with none: stock for that scene, no image call (Task 6 `Script` test, Task 8 `Visuals` tests).
5. Old data: a stored 0.1 spec still validates, and a job whose progress says `stock` still renders its steps (Task 5 spec test, Task 10 web test).

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `api/test/support/images.ex` | create | Tiny JPEG/PNG bytes for tests |
| `api/lib/retake/media/image.ex` | create | Width, height, mime from JPEG/PNG bytes |
| `api/lib/retake/providers.ex`, `providers/config.ex`, `providers/provider.ex` | modify | Optional `image` capability |
| `api/lib/retake/providers/adapters/cloudflare_workers_ai_image.ex` | create | Cloudflare adapter |
| `api/lib/retake/providers/adapters.ex`, `api/config/test.exs` | modify | Register the adapter and its test stub |
| `api/lib/mix/tasks/retake.image.ex`, `justfile` | create/modify | `mix retake.image`, `just image` |
| `config/providers.example.toml` | modify | `cloudflare-flux` provider, `image` slot in `free` |
| `spec/video.schema.json`, `spec/SPEC.md`, `spec/examples/*.json`, `fixtures/specs/*.json` | modify | Spec 0.2 |
| `api/lib/retake/spec.ex`, `crates/retake_render/src/spec.rs` | modify | Migration; Rust accepts 0.2 and `image_prompt` |
| `api/lib/retake/pipeline/script.ex`, `api/lib/mix/tasks/retake.script.ex` | modify | `image_prompt` in the script |
| `api/lib/retake/pipeline/images.ex` | create | One cached image call to a spec asset |
| `api/lib/retake/pipeline/visuals.ex` | create | Generated first, stock fallback |
| `api/lib/retake/pipeline.ex`, `pipeline/assemble.ex`, `api/lib/mix/tasks/retake.video.ex` | modify | Use `Visuals`; event `:visual` |
| `api/test/support/scripted_adapter.ex` | modify | `image` role and an `image_prompt` in the canned script |
| `web/src/lib/{steps,scenes,types}.ts`, `web/src/screens/Result.tsx` | modify | "Visuals" row, `visual` entries |
| `DECISIONS.md`, `PROGRESS.md`, `features.json` | modify | D25-D27, log, sub-steps |

---

### Task 1: Image size reader (`Retake.Media.Image`) and test image bytes

**Files:**
- Create: `api/test/support/images.ex`
- Create: `api/lib/retake/media/image.ex`
- Test: `api/test/retake/media/image_test.exs`
- Modify: `features.json` (F16 `state` to `"active"`)

**Interfaces:**
- Produces: `Retake.Media.Image.dimensions(binary()) :: {:ok, %{width: pos_integer(), height: pos_integer(), mime: String.t()}} | {:error, :unknown_format | :truncated | :no_size | :bad_size | :bad_jpeg}`
- Produces (tests only): `Retake.Test.Images.jpeg(width, height) :: binary()`, `Retake.Test.Images.png(width, height) :: binary()`

- [ ] **Step 1: Mark F16 active.** In `features.json`, in the object with `"id": "F16-generated-images"`, change `"state": "not_started"` to `"state": "active"` (AGENTS rule 1: one feature at a time).

- [ ] **Step 2: Write the test support module**

`api/test/support/images.ex`:

```elixir
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
```

- [ ] **Step 3: Write the failing test**

`api/test/retake/media/image_test.exs`:

```elixir
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
```

- [ ] **Step 4: Run it and see it fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/media/image_test.exs 2>&1 | tail -15
```
Expected: compile error or failures: `Retake.Media.Image.dimensions/1 is undefined` (module not available).

- [ ] **Step 5: Write the implementation**

`api/lib/retake/media/image.ex`:

```elixir
defmodule Retake.Media.Image do
  @moduledoc """
  Reads the size and the type of a JPEG or PNG from its first bytes. Pure Elixir on two
  simple containers, so no media library is involved (AGENTS.md rule 8).

  A PNG starts with an 8 byte signature and an `IHDR` chunk holding the size. A JPEG is a
  list of segments, each `0xFF`, a marker byte, and (for most markers) a 16 bit length that
  counts itself; the frame header (a "SOF" marker) holds the size and comes before the image
  data.
  """

  # SOF0 to SOF15 are frame headers, except C4 (Huffman tables), C8 (reserved) and CC
  # (arithmetic coding conditioning), which sit in the same range.
  @frame_markers Enum.to_list(0xC0..0xCF) -- [0xC4, 0xC8, 0xCC]

  @type info :: %{width: pos_integer(), height: pos_integer(), mime: String.t()}

  @doc "Width, height and mime type of an image's bytes."
  @spec dimensions(binary()) :: {:ok, info()} | {:error, atom()}
  def dimensions(<<0xFF, 0xD8, segments::binary>>), do: jpeg(segments)

  def dimensions(
        <<0x89, "PNG\r\n", 0x1A, "\n", _length::32, "IHDR", width::32, height::32,
          _rest::binary>>
      ) do
    size(width, height, "image/png")
  end

  def dimensions(_other), do: {:error, :unknown_format}

  # A fill byte: any number of 0xFF may come before a marker.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, _length::16, _precision, height::16, width::16, _rest::binary>>)
       when marker in @frame_markers do
    size(width, height, "image/jpeg")
  end

  # The image data (or its end) came before any frame header.
  defp jpeg(<<0xFF, marker, _rest::binary>>) when marker in [0xDA, 0xD9], do: {:error, :no_size}

  # Markers with no length: restart markers, the start of image and TEM.
  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD8 or marker == 0x01 do
    jpeg(rest)
  end

  defp jpeg(<<0xFF, marker, length::16, rest::binary>>) when marker != 0 and length >= 2 do
    skip = length - 2

    case rest do
      <<_segment::binary-size(skip), tail::binary>> -> jpeg(tail)
      _ -> {:error, :truncated}
    end
  end

  defp jpeg(<<>>), do: {:error, :truncated}
  defp jpeg(_other), do: {:error, :bad_jpeg}

  defp size(width, height, mime) when width > 0 and height > 0 do
    {:ok, %{width: width, height: height, mime: mime}}
  end

  defp size(_width, _height, _mime), do: {:error, :bad_size}
end
```

- [ ] **Step 6: Run the test and see it pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/media/image_test.exs 2>&1 | tail -8
```
Expected: `10 tests, 0 failures`.

- [ ] **Step 7: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/media/image.ex api/test/support/images.ex api/test/retake/media/image_test.exs features.json
git commit -m "feat(api): read image size from JPEG and PNG bytes" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: An optional `image` capability in the provider layer

**Files:**
- Modify: `api/lib/retake/providers/config.ex` (lines 5, 13-14, 238-250)
- Modify: `api/lib/retake/providers.ex` (lines 17, 21-31)
- Modify: `api/lib/retake/providers/provider.ex` (line 13)
- Test: `api/test/retake/providers/config_test.exs`, `api/test/retake/providers_test.exs`

**Interfaces:**
- Produces: a profile may contain an `image` slot; `Retake.Providers.resolve(config, profile, :image)` returns `{:ok, [Provider.t()]}` or `{:error, {:capability_not_configured, :image}}` when the profile has no image slot. Providers may declare `capability = "image"`.

- [ ] **Step 1: Write the failing config tests.** In `api/test/retake/providers/config_test.exs`, inside `describe "validation"`, after the test `"a profile must cover every capability"`, add:

```elixir
    test "the image capability is optional in a profile" do
      assert {:ok, config} = Config.parse(@minimal)
      refute Map.has_key?(config.profiles["dev"], :image)
    end

    test "a profile may use an image provider" do
      toml =
        @minimal
        |> String.replace(
          ~s(music = { use = "m", fallbacks = [] }\n),
          ~s(music = { use = "m", fallbacks = [] }\nimage = { use = "i", fallbacks = [] }\n)
        )
        |> Kernel.<>("""

        [providers.i]
        capability = "image"
        adapter = "cloudflare_workers_ai_image"
        """)

      assert {:ok, config} = Config.parse(toml)
      assert config.profiles["dev"].image == %{use: "i", fallbacks: []}
      assert config.providers["i"].capability == :image
    end

    test "an image slot must name an image provider" do
      toml =
        String.replace(
          @minimal,
          ~s(music = { use = "m", fallbacks = [] }\n),
          ~s(music = { use = "m", fallbacks = [] }\nimage = { use = "k", fallbacks = [] }\n)
        )

      assert_error(Config.parse(toml), "profiles.dev.image.use", "stock")
    end
```

- [ ] **Step 2: Write the failing resolve tests.** In `api/test/retake/providers_test.exs`, inside `describe "resolve/3"` after the `"unknown capability"` test, add:

```elixir
    test "a profile with no image slot has no image provider", %{config: config} do
      assert Providers.resolve(config, "dev", :image) ==
               {:error, {:capability_not_configured, :image}}
    end

    test "resolves the image provider when the profile has one" do
      toml =
        @config
        |> String.replace(
          ~s(music = { use = "m", fallbacks = [] }\n),
          ~s(music = { use = "m", fallbacks = [] }\nimage = { use = "i", fallbacks = [] }\n)
        )
        |> Kernel.<>("""

        [providers.i]
        capability = "image"
        adapter = "cloudflare_workers_ai_image"
        """)

      {:ok, config} = Config.parse(toml)
      assert {:ok, [%{name: "i"}]} = Providers.resolve(config, "dev", :image)
    end
```

- [ ] **Step 3: Run and see them fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/providers/config_test.exs test/retake/providers_test.exs 2>&1 | tail -30
```
Expected: 4 failures (unknown capability "image"; `Providers.resolve` raising `KeyError`/returning `{:unknown_capability, :image}`). The "optional in a profile" test already passes (the config never required `image`); that is fine.

- [ ] **Step 4: Edit `config.ex`.** Replace lines 13-14:

```elixir
  @capability_list [llm: "llm", tts: "tts", stt: "stt", stock: "stock", music: "music"]
  @provider_capabilities Map.new(@capability_list, fn {atom, name} -> {name, atom} end)
                         |> Map.put("any", :any)
```
with:

```elixir
  @capability_list [llm: "llm", tts: "tts", stt: "stt", stock: "stock", music: "music"]
  # Not every profile needs these: without a slot the pipeline does without (no `image` slot
  # means stock only).
  @optional_capability_list [image: "image"]
  @provider_capabilities Map.new(
                           @capability_list ++ @optional_capability_list,
                           fn {atom, name} -> {name, atom} end
                         )
                         |> Map.put("any", :any)
```
Replace `parse_profile/3` (lines 238-250) with:

```elixir
  defp parse_profile(name, slots, providers) do
    slots = if is_map(slots), do: slots, else: %{}

    Enum.reduce(@capability_list ++ @optional_capability_list, {%{}, []}, fn {capability,
                                                                              capability_name},
                                                                             {profile, errors} ->
      path = "profiles.#{name}.#{capability_name}"
      raw = Map.get(slots, capability_name)

      if is_nil(raw) and Keyword.has_key?(@optional_capability_list, capability) do
        {profile, errors}
      else
        case parse_slot(raw, capability, path, providers) do
          {:ok, slot} -> {Map.put(profile, capability, slot), errors}
          {:error, new_errors} -> {profile, errors ++ new_errors}
        end
      end
    end)
  end
```
In the moduledoc (line 5) change `(llm, tts, stt, stock, music)` to `(llm, tts, stt, stock, music, and optionally image)`.

- [ ] **Step 5: Edit `providers.ex`.** Line 17 becomes `@capabilities [:llm, :tts, :stt, :stock, :music, :image]`. Replace `resolve/3` and add a helper:

```elixir
  @doc """
  The providers for `capability` in `profile`: the primary first, then the fallbacks. Every
  profile covers every capability except `:image`; a profile with no `image` slot has no
  image provider (`{:capability_not_configured, :image}`).
  """
  @spec resolve(Config.t(), String.t(), atom()) ::
          {:ok, [Provider.t()]}
          | {:error,
             {:unknown_profile, String.t()}
             | {:unknown_capability, atom()}
             | {:capability_not_configured, atom()}}
  def resolve(%Config{} = config, profile, capability) do
    with {:ok, slots} <- fetch(config.profiles, profile, :unknown_profile),
         true <- capability in @capabilities || {:error, {:unknown_capability, capability}},
         {:ok, slot} <- slot(slots, capability) do
      {:ok, Enum.map([slot.use | slot.fallbacks], &Map.fetch!(config.providers, &1))}
    end
  end

  defp slot(slots, capability) do
    case Map.fetch(slots, capability) do
      {:ok, slot} -> {:ok, slot}
      :error -> {:error, {:capability_not_configured, capability}}
    end
  end
```
(Delete the old one-line `@doc`/`@spec`/`def resolve` it replaces.)

- [ ] **Step 6: Edit `provider.ex` line 13:** `@type capability :: :llm | :tts | :stt | :stock | :music | :image | :any`.

- [ ] **Step 7: Run and see them pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/providers test/retake/providers_test.exs 2>&1 | tail -8
```
Expected: `0 failures` (the earlier count plus 5 new tests).

- [ ] **Step 8: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/providers.ex api/lib/retake/providers/config.ex api/lib/retake/providers/provider.ex api/test/retake/providers/config_test.exs api/test/retake/providers_test.exs
git commit -m "feat(api): optional image capability in provider profiles" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The Cloudflare Workers AI image adapter

**Files:**
- Create: `api/lib/retake/providers/adapters/cloudflare_workers_ai_image.ex`
- Modify: `api/lib/retake/providers/adapters.ex` (the `@builtin` map)
- Modify: `api/config/test.exs` (the `req_options` map)
- Test: `api/test/retake/providers/adapters/cloudflare_workers_ai_image_test.exs`

**Interfaces:**
- Consumes: `Retake.Media.Image.dimensions/1`, `Retake.Providers.Adapters.Http.{options/1, failure/2, redact/2}`, `Retake.Test.Images.{jpeg/2, png/2}`.
- Produces: adapter `"cloudflare_workers_ai_image"` (`Retake.Providers.Adapters.CloudflareWorkersAIImage`). Request: `%{"prompt" => String.t()}` (+ optional `"steps"`). Output: `{:ok, {:binary, bytes, "jpg" | "png"}, %{cost_usd: 0.0, units: %{"steps" => n}}}`. Errors: `{:http, status, message}`, `{:transport, reason}`, `{:unexpected_response, why}`, `{:bad_request, why}`, `{:bad_provider_config, why}`.

- [ ] **Step 1: Register the test stub.** In `api/config/test.exs`, add one entry to the `req_options` map (after the `OpenAICompatibleTranscription` entry, adding a comma after its closing `]`):

```elixir
    Retake.Providers.Adapters.CloudflareWorkersAIImage => [
      plug: {Req.Test, Retake.Providers.Adapters.CloudflareWorkersAIImage}
    ]
```

- [ ] **Step 2: Write the failing test**

`api/test/retake/providers/adapters/cloudflare_workers_ai_image_test.exs`:

```elixir
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
      send(test, {:request, conn, Jason.decode!(raw)})
      reply.(conn)
    end)
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
      assert Flux.normalize_request(provider(%{"steps" => 6}), %{"prompt" => "p", "steps" => 2})["steps"] == 2
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
      assert {:ok, _, _} = Flux.call(provider(%{"base_url" => "https://cf.test/v9/"}), @token, request())
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
      assert {:ok, _, %{units: %{"steps" => 8}}} = Flux.call(provider(), @token, request(%{"steps" => 8}))
    end
  end

  describe "errors" do
    test "an HTTP error carries Cloudflare's message" do
      serve(failure(429, "daily allowance used up"))
      assert {:error, {:http, 429, "daily allowance used up"}} = Flux.call(provider(), @token, request())
    end

    test "the token never appears in an error" do
      serve(failure(400, "bad request near #{@token}"))
      assert {:error, {:http, 400, message}} = Flux.call(provider(), @token, request())
      refute message =~ @token
      assert message =~ "[redacted]"
    end

    test "an error body without Cloudflare's shape is still an error" do
      serve(fn conn -> Plug.Conn.send_resp(conn, 502, "<html>bad gateway</html>") end)
      assert {:error, {:http, 502, "<html>bad gateway</html>"}} = Flux.call(provider(), @token, request())
    end

    test "a transport failure" do
      serve(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, {:transport, :timeout}} = Flux.call(provider(), @token, request())
    end

    test "a 200 with no image" do
      serve(fn conn -> Req.Test.json(conn, %{"success" => true, "result" => %{}}) end)
      assert {:error, {:unexpected_response, "the reply had no image"}} = Flux.call(provider(), @token, request())
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

  describe "bad settings and bad requests" do
    test "no token" do
      assert {:error, {:bad_provider_config, message}} = Flux.call(provider(), nil, request())
      assert message =~ "api_key_env"
    end

    test "no model" do
      options = Map.delete(provider().options, "model")
      assert {:error, {:bad_provider_config, message}} = Flux.call(%{provider() | options: options}, @token, request())
      assert message =~ "model"
    end

    test "no account id in the environment" do
      p = provider(%{"account_id_env" => "RETAKE_TEST_CF_ACCOUNT_NOT_SET"})
      assert {:error, {:bad_provider_config, message}} = Flux.call(p, @token, request())
      assert message =~ "RETAKE_TEST_CF_ACCOUNT_NOT_SET"
    end

    test "a blank prompt" do
      assert {:error, {:bad_request, "prompt must not be blank"}} = Flux.call(provider(), @token, request(%{"prompt" => "   "}))
    end

    test "a prompt over Cloudflare's 2048 characters" do
      long = String.duplicate("a", 2049)
      assert {:error, {:bad_request, message}} = Flux.call(provider(), @token, request(%{"prompt" => long}))
      assert message =~ "2048"
    end

    test "no prompt" do
      assert {:error, {:bad_request, "the request needs a prompt"}} = Flux.call(provider(), @token, %{"steps" => 4})
    end

    test "steps outside 1 to 8" do
      assert {:error, {:bad_request, message}} = Flux.call(provider(), @token, request(%{"steps" => 9}))
      assert message =~ "1 to 8"
      assert {:error, {:bad_request, _}} = Flux.call(provider(), @token, request(%{"steps" => 0}))
    end
  end
end
```

- [ ] **Step 3: Run and see it fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/providers/adapters/cloudflare_workers_ai_image_test.exs 2>&1 | tail -12
```
Expected: compile error, `Retake.Providers.Adapters.CloudflareWorkersAIImage` is not available.

- [ ] **Step 4: Register the adapter.** In `api/lib/retake/providers/adapters.ex` add to `@builtin` (after the `"pixabay"` entry, with a comma added after it):

```elixir
    "cloudflare_workers_ai_image" => Retake.Providers.Adapters.CloudflareWorkersAIImage
```

- [ ] **Step 5: Write the adapter**

`api/lib/retake/providers/adapters/cloudflare_workers_ai_image.ex`:

```elixir
defmodule Retake.Providers.Adapters.CloudflareWorkersAIImage do
  @moduledoc """
  The `cloudflare_workers_ai_image` adapter: text to image on Cloudflare Workers AI
  (FLUX.1 [schnell] and its relatives). Settings come from the provider in
  `config/providers.toml`: `model` (required, for example
  `"@cf/black-forest-labs/flux-1-schnell"`), `account_id_env` (the environment variable that
  holds the Cloudflare account id; default `"CLOUDFLARE_ACCOUNT_ID"`), `steps` (default 4, at
  most 8), `base_url` (default `"https://api.cloudflare.com/client/v4"`) and `timeout_ms`.
  The API token is the provider's `api_key_env`, sent as a bearer token.

  The request (string keys):

      %{"prompt" => "A dim bedroom at night, a phone glowing on a pillow, vertical shot."}

  `steps` is optional in the request: `normalize_request/2` fills it in from the provider, so it
  is part of the cache key and the asset's provenance. The output is `{:binary, image, "jpg" |
  "png"}`, checked to be an image whose size can be read (`Retake.Media.Image`). On the free
  plan a call costs nothing: usage is reported as `cost_usd: 0.0` and `units: %{"steps" => n}`.

  The REST API wraps its answer as `{"result": {"image": "<base64>"}, "success": true}`; a bare
  `{"image": "<base64>"}` is accepted too.

  Errors: `{:http, status, message}`, `{:transport, reason}`, `{:unexpected_response, why}`,
  `{:bad_request, why}` (blank or too long a prompt, steps out of range) and
  `{:bad_provider_config, why}` (no token, model or account id).
  """

  @behaviour Retake.Providers.Adapter

  alias Retake.Media.Image
  alias Retake.Providers.Adapters.Http
  alias Retake.Providers.Provider

  @default_base_url "https://api.cloudflare.com/client/v4"
  @default_account_env "CLOUDFLARE_ACCOUNT_ID"
  @default_steps 4
  @max_steps 8
  @max_prompt 2048
  @default_timeout 60_000
  @extensions %{"image/jpeg" => "jpg", "image/png" => "png"}

  @impl true
  def normalize_request(%Provider{} = provider, request) do
    Map.put_new(request, "steps", provider.options["steps"] || @default_steps)
  end

  @impl true
  def call(%Provider{} = provider, api_key, request) do
    with {:ok, token} <- token(provider, api_key),
         {:ok, model} <- required(provider, "model"),
         {:ok, account} <- account_id(provider),
         {:ok, prompt} <- prompt(request["prompt"]),
         {:ok, steps} <- steps(request["steps"] || provider.options["steps"] || @default_steps) do
      provider
      |> http_request(account, model, %{"prompt" => prompt, "steps" => steps}, token)
      |> Req.request()
      |> handle(steps, token)
    end
  end

  # --- settings and request checks ------------------------------------------------------

  defp token(_provider, key) when is_binary(key) and key != "", do: {:ok, key}

  defp token(provider, _key) do
    {:error,
     {:bad_provider_config,
      "provider #{inspect(provider.name)} needs an api_key_env naming the Cloudflare API token"}}
  end

  defp required(provider, name) do
    case provider.options[name] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:bad_provider_config, "provider #{inspect(provider.name)} needs a #{name}"}}
    end
  end

  defp account_id(provider) do
    variable = provider.options["account_id_env"] || @default_account_env

    case variable |> System.get_env() |> to_string() |> String.trim() do
      "" ->
        {:error, {:bad_provider_config, "no Cloudflare account id: export #{variable}=..."}}

      account ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, account) do
          {:ok, account}
        else
          {:error,
           {:bad_provider_config, "#{variable} does not look like a Cloudflare account id"}}
        end
    end
  end

  defp prompt(prompt) when is_binary(prompt) do
    cond do
      String.trim(prompt) == "" ->
        {:error, {:bad_request, "prompt must not be blank"}}

      String.length(prompt) > @max_prompt ->
        {:error, {:bad_request, "prompt must be at most #{@max_prompt} characters"}}

      true ->
        {:ok, prompt}
    end
  end

  defp prompt(_other), do: {:error, {:bad_request, "the request needs a prompt"}}

  defp steps(steps) when is_integer(steps) and steps >= 1 and steps <= @max_steps,
    do: {:ok, steps}

  defp steps(_other) do
    {:error, {:bad_request, "steps must be a whole number from 1 to #{@max_steps}"}}
  end

  # --- request ----------------------------------------------------------------------------

  defp http_request(provider, account, model, body, token) do
    base = String.trim_trailing(provider.options["base_url"] || @default_base_url, "/")

    [
      method: :post,
      url: "#{base}/accounts/#{account}/ai/run/#{model}",
      json: body,
      auth: {:bearer, token},
      receive_timeout: provider.options["timeout_ms"] || @default_timeout,
      retry: false
    ]
    |> Keyword.merge(Http.options(__MODULE__))
    |> Req.new()
  end

  # --- response ---------------------------------------------------------------------------

  defp handle({:ok, %Req.Response{status: 200, body: body}}, steps, _token) do
    with {:ok, encoded} <- image_field(body),
         {:ok, bytes} <- decode(encoded),
         {:ok, %{mime: mime}} <- image(bytes) do
      {:ok, {:binary, bytes, Map.fetch!(@extensions, mime)},
       %{cost_usd: 0.0, units: %{"steps" => steps}}}
    end
  end

  # Cloudflare's own error shape: {"success": false, "errors": [{"code": .., "message": ..}]}.
  defp handle(
         {:ok, %Req.Response{status: status, body: %{"errors" => [%{"message" => message} | _]}}},
         _steps,
         token
       )
       when status != 200 and is_binary(message) do
    {:error, {:http, status, message |> Http.redact(token) |> String.slice(0, 300)}}
  end

  defp handle(other, _steps, token), do: Http.failure(other, token)

  defp image_field(%{"result" => %{"image" => image}}) when is_binary(image) and image != "",
    do: {:ok, image}

  defp image_field(%{"image" => image}) when is_binary(image) and image != "", do: {:ok, image}
  defp image_field(_body), do: {:error, {:unexpected_response, "the reply had no image"}}

  defp decode(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:unexpected_response, "the image in the reply is not valid base64"}}
    end
  end

  defp image(bytes) do
    case Image.dimensions(bytes) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        {:error, {:unexpected_response, "the reply is not a readable image (#{reason})"}}
    end
  end
end
```

- [ ] **Step 6: Run and see it pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/providers/adapters/cloudflare_workers_ai_image_test.exs 2>&1 | tail -12
```
Expected: `0 failures` (25 tests). If a test about `conn.request_path` fails because `@` was percent-encoded, change that one assertion to compare `URI.decode(conn.request_path)`; report it back rather than loosening other checks.

- [ ] **Step 7: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/providers/adapters/cloudflare_workers_ai_image.ex api/lib/retake/providers/adapters.ex api/config/test.exs api/test/retake/providers/adapters/cloudflare_workers_ai_image_test.exs
git commit -m "feat(api): Cloudflare Workers AI image adapter" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Example config, `mix retake.image`, `just image`, and the real probe

**Files:**
- Modify: `config/providers.example.toml`
- Create: `api/lib/mix/tasks/retake.image.ex`
- Modify: `justfile` (after the `stock` recipe)
- Test: `api/test/retake/providers/config_test.exs` (the example-config tests)

**Interfaces:**
- Consumes: Task 2 (optional `image` slot), Task 3 (adapter), `Retake.Providers.Client.{from_file/2, call/4}`, `Retake.Cache.Entry`, `Retake.Storage.{fetch/2, local_path/2}`, `Retake.Media.Image`, `Retake.CLI.{start_services/0, default_config_path/0, describe/2}`.
- Produces: provider `cloudflare-flux` and an `image` slot in the `free` profile; `mix retake.image [--steps N] [--force] [--profile P] [--config PATH] "prompt"`; `just image`.

- [ ] **Step 1: Write the failing example-config tests.** In `config_test.exs`, in `describe "the shipped example config"`, add:

```elixir
    test "the free profile makes images with Cloudflare; dev and test have no image slot" do
      {:ok, config} = Config.load(@example)

      assert config.profiles["free"].image == %{use: "cloudflare-flux", fallbacks: []}
      refute Map.has_key?(config.profiles["dev"], :image)
      refute Map.has_key?(config.profiles["test"], :image)

      flux = config.providers["cloudflare-flux"]
      assert flux.capability == :image
      assert flux.adapter == "cloudflare_workers_ai_image"
      assert flux.api_key_env == "CLOUDFLARE_API_TOKEN"
      assert flux.options["account_id_env"] == "CLOUDFLARE_ACCOUNT_ID"
      assert flux.options["model"] == "@cf/black-forest-labs/flux-1-schnell"
      assert flux.rate_limit == %{requests_per_day: 150}
    end
```

- [ ] **Step 2: Run, see it fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/providers/config_test.exs 2>&1 | tail -12
```
Expected: 1 failure (`config.profiles["free"].image` is a `KeyError`).

- [ ] **Step 3: Edit `config/providers.example.toml`.**
  1. In the header comment, change `# - A capability is a job Retake needs done: llm, tts, stt, stock, music.` to `# - A capability is a job Retake needs done: llm, tts, stt, stock, music, and optionally\n#   image (a profile without an image slot uses stock only).`
  2. In `[profiles.free]`, after the `music = ...` line add:
     ```toml
     image = { use = "cloudflare-flux", fallbacks = [] }   # generated images; with no Cloudflare keys set, stock is used
     ```
  3. After the `# --- Stock visuals` block's providers (before `# --- Music`), add:
     ```toml
     # --- Generated images (optional) --------------------------------------------
     # Cloudflare Workers AI. Needs two environment variables: an API token with Workers AI
     # access (CLOUDFLARE_API_TOKEN) and your account id (CLOUDFLARE_ACCOUNT_ID).

     [providers.cloudflare-flux]
     capability = "image"
     adapter = "cloudflare_workers_ai_image"
     api_key_env = "CLOUDFLARE_API_TOKEN"
     account_id_env = "CLOUDFLARE_ACCOUNT_ID"
     model = "@cf/black-forest-labs/flux-1-schnell"
     steps = 4
     timeout_ms = 60000
     # The free plan allows 10,000 Neurons a day: about 170 images at 4 steps if the output
     # is 1024x1024 (check with `just image`). Stay under it.
     rate_limit = { requests_per_day = 150 }
     ```

- [ ] **Step 4: Run, see it pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/providers/config_test.exs 2>&1 | tail -6
```
Expected: `0 failures`.

- [ ] **Step 5: Write the mix task**

`api/lib/mix/tasks/retake.image.ex`:

```elixir
defmodule Mix.Tasks.Retake.Image do
  @shortdoc "Makes an image for a prompt with the profile's image provider"

  @moduledoc """
  Makes one image for real: sends the prompt to the image provider of the chosen profile,
  stores the picture in `.retake/store` and tells you where it is, how big it is and whether it
  came from the cache.

      mix retake.image "a dim bedroom at night, a phone glowing on a pillow, vertical shot"
      mix retake.image --steps 8 "a calm sea at sunrise, vertical shot, soft light"

  Needs `config/providers.toml` with an `image` slot in the profile (see
  `config/providers.example.toml`) and, for Cloudflare, `CLOUDFLARE_API_TOKEN` and
  `CLOUDFLARE_ACCOUNT_ID` in your environment.

  Options:

    * `--steps N`     how many diffusion steps, 1 to 8 (default: the provider's setting, 4)
    * `--force`       ask the provider again even if the answer is in the cache
    * `--profile NAME`, `--config PATH` as for `mix help retake.script`

  A repeated prompt is answered from the cache: no call is made and no allowance is used.
  A video is 9:16, so the size printed here tells you how much of a picture `cover` keeps.
  """

  use Mix.Task

  alias Retake.Cache.Entry
  alias Retake.CLI
  alias Retake.Media.Image
  alias Retake.Providers
  alias Retake.Providers.Client
  alias Retake.Storage

  @switches [profile: :string, config: :string, steps: :integer, force: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, words, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or words == [] do
      Mix.raise(~s|usage: mix retake.image [options] "image prompt"   (see mix help retake.image)|)
    end

    Mix.Task.run("app.config")
    CLI.start_services()

    path = opts[:config] || CLI.default_config_path()

    case Client.from_file(path, profile: opts[:profile]) do
      {:ok, client} -> generate(client, Enum.join(words, " "), opts)
      {:error, reason} -> Mix.raise(CLI.describe(reason, path))
    end
  end

  defp generate(client, prompt, opts) do
    case Providers.resolve(client.config, client.profile, :image) do
      {:ok, providers} ->
        names = Enum.map_join(providers, ", then ", & &1.name)
        Mix.shell().info("profile #{client.profile}, image: #{names}")

      {:error, {:capability_not_configured, :image}} ->
        Mix.raise(
          "profile #{client.profile} has no image provider: add an `image` slot " <>
            "(see config/providers.example.toml)"
        )

      {:error, reason} ->
        Mix.raise(CLI.describe(reason, nil))
    end

    request =
      if opts[:steps], do: %{"prompt" => prompt, "steps" => opts[:steps]}, else: %{"prompt" => prompt}

    case Client.call(client, :image, request, force: opts[:force] || false) do
      {:ok, %Entry{result: {:asset, ref}} = entry, outcome} -> print(client, entry, ref, outcome)
      {:ok, entry, _outcome} -> Mix.raise("unexpected result: #{inspect(entry.result)}")
      {:error, reason} -> Mix.raise(CLI.describe(reason, nil))
    end
  end

  defp print(client, entry, ref, outcome) do
    shell = Mix.shell()

    shell.info("\nprompt:    #{entry.request["prompt"]}")
    shell.info("steps:     #{entry.request["steps"]}")
    shell.info("provider:  #{entry.provider} (#{entry.model})")

    shell.info(
      if outcome == :hit,
        do: "answered from the cache: no call was made",
        else: "made just now (cost #{entry.cost.amount} #{entry.cost.currency})"
    )

    with {:ok, bytes} <- Storage.fetch(client.storage, ref.uri),
         {:ok, %{width: width, height: height, mime: mime}} <- Image.dimensions(bytes) do
      shell.info("size:      #{width}x#{height} #{mime}, #{byte_size(bytes)} bytes")

      if width >= height do
        # Cover fit scales the picture to fill the frame height; the frame is 1080 wide for 1920 tall.
        share = round(100 * (1080 / 1920) * height / width)

        shell.info(
          "note:      not portrait: cover fit on a 1080x1920 video shows about #{share}% of its width"
        )
      end
    end

    shell.info("stored as: #{ref.uri}")

    case Storage.local_path(client.storage, ref.uri) do
      {:ok, file} ->
        shell.info("file:      #{file}")
        if windows = windows_path(file), do: shell.info("from Windows: #{windows}")

      {:error, _} ->
        :ok
    end
  end

  # Inside WSL the same file is reachable from Windows at \\wsl$\<distro>\<path>.
  defp windows_path(file) do
    if distro = System.get_env("WSL_DISTRO_NAME") do
      "\\\\wsl$\\#{distro}" <> String.replace(file, "/", "\\")
    end
  end
end
```

(A 1024x1024 image gives `share = 56`: the frame shows 56% of the picture's width.)

- [ ] **Step 6: Add the recipe.** In `justfile`, after the `stock` recipe, add:

```
# Make an image for a prompt with the real image provider: `just image "a calm sea at sunrise, vertical shot"`.
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (see `mix help retake.image`).
image *args:
    cd api && mix retake.image {{args}}
```

- [ ] **Step 7: Compile and format check (User runs)**

```bash
cd api && unset MIX_ENV && mix format && mix compile --warnings-as-errors 2>&1 | tail -5
```
Expected: no warnings.

- [ ] **Step 8: THE REAL PROBE (User runs). This decides what happens in later tasks.**

One-time setup. In the Cloudflare dashboard: Workers AI, "Use REST API", create a Workers AI API token, and note your account id (the menu names may differ slightly). Add both to `~/.config/retake/env` (never paste the values in chat):

```bash
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ACCOUNT_ID=...
```
Add the provider and the slot to your own `config/providers.toml` (`just setup` only copies the example when the file is missing): the `image = {...}` line in `[profiles.free]` and the `[providers.cloudflare-flux]` block from Step 3. Then:

```bash
source ~/.config/retake/env
just image "a dim bedroom at night, a phone glowing on a pillow, vertical shot, soft light"
just image "a dim bedroom at night, a phone glowing on a pillow, vertical shot, soft light"
```
Expected, first run: `profile free, image: cloudflare-flux`, then prompt, steps 4, `provider: cloudflare-flux (@cf/black-forest-labs/flux-1-schnell)`, `made just now (cost 0.0 USD)`, `size: WxH image/jpeg, N bytes`, `stored as: store://assets/<hash>.jpg`, a `file:` path and a `from Windows:` path. Second run: `answered from the cache: no call was made`.

Open the picture from the `from Windows:` path. **Report back:** the size line, whether a `note: not portrait` line appeared, how long the first call took, and whether the picture follows the prompt. If the call fails, paste only the shortest error line (no keys). The reply envelope and the size are the two unverified facts; if the adapter says `the reply had no image`, paste the first 200 characters of the JSON the API returned (with `curl`, token redacted) so the field name can be fixed in `image_field/1`.

**Decision gate:** if the size is square, tell the user the cost (cover fit shows about 56% of the width) and ask which of these to do before Task 6: (a) go on and rely on prompting for a centred subject (the default in Task 6), (b) try `@cf/black-forest-labs/flux-2-klein-4b` and check whether it accepts a portrait size, (c) plan a blurred-background fit in the renderer as a separate feature. Do not start (b) or (c) without the user's answer.

- [ ] **Step 9: Hand over the commit (User runs)**

```bash
git add config/providers.example.toml api/lib/mix/tasks/retake.image.ex justfile api/test/retake/providers/config_test.exs
git commit -m "feat(api): mix retake.image and the cloudflare-flux provider in the example config" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Spec 0.2 (`image_prompt`) with a 0.1 migration

**Files:**
- Modify: `spec/video.schema.json` (line 10 and the `intent` properties around line 223)
- Modify: `spec/SPEC.md` (lines 1, 18-20, 85, 94-105)
- Modify: `spec/examples/minimal.json`, `spec/examples/explainer.json`, `fixtures/specs/minimal.json`, `fixtures/specs/cuts.json`, `fixtures/specs/multi.json` (the `spec_version` line)
- Modify: `api/lib/retake/spec.ex`
- Modify: `api/lib/retake/pipeline/assemble.ex` (line 91 only; the rest of Assemble changes in Task 9)
- Modify: `crates/retake_render/src/spec.rs` (lines 16, 97-101)
- Test: `api/test/retake/spec_test.exs`, `api/test/retake/pipeline/assemble_test.exs:139`, `api/test/retake/render_test.exs:100`, `crates/retake_render/tests/spec.rs:94-99`

**Interfaces:**
- Produces: `Retake.Spec.migrate(term()) :: term()` (0.1 to 0.2: sets the version; anything else unchanged); `Retake.Spec.validate/1` and `load/1` migrate first and return the 0.2 spec; schema accepts optional `scenes[].intent.image_prompt` (string, max 600); the Rust parser accepts only `"0.2"` and the new field.

- [ ] **Step 1: Write the failing Elixir tests.** In `api/test/retake/spec_test.exs`:
  - line 25: change `"0.1"` to `"0.2"`.
  - line 59: change the test name to `"an unknown spec_version is rejected"` and `"0.2"` to `"0.3"`.
  - add a new describe after `describe "example specs"`:

```elixir
  describe "versions" do
    test "a 0.1 spec is migrated to 0.2" do
      old = "minimal.json" |> example() |> set(["spec_version"], "0.1")
      assert {:ok, %{"spec_version" => "0.2"}} = Spec.validate(old)
    end

    test "migrate/1 changes only the version of a 0.1 spec and leaves anything else alone" do
      old = "minimal.json" |> example() |> set(["spec_version"], "0.1")

      assert Spec.migrate(old) == set(old, ["spec_version"], "0.2")
      assert Spec.migrate(%{"spec_version" => "9.9"}) == %{"spec_version" => "9.9"}
      assert Spec.migrate("not a map") == "not a map"
    end

    test "a scene's intent may carry an image_prompt" do
      spec =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "intent", "image_prompt"], "A dim room, vertical shot.")

      assert {:ok, _} = Spec.validate(spec)
    end

    test "an image_prompt over 600 characters is rejected" do
      result =
        "minimal.json"
        |> example()
        |> set(["scenes", Access.at(0), "intent", "image_prompt"], String.duplicate("a", 601))
        |> Spec.validate()

      assert_error(result, "/scenes/0/intent/image_prompt", :schema)
    end
  end
```
  - `api/test/retake/pipeline/assemble_test.exs:139`: `"0.1"` to `"0.2"`.
  - `api/test/retake/render_test.exs:100`: `"0.2"` to `"0.3"` (the test is about an unsupported version).

- [ ] **Step 2: Write the failing Rust tests.** In `crates/retake_render/tests/spec.rs`: change `spec_rejects_unsupported_version` to use `"0.3"`, and add after it:

```rust
#[test]
fn spec_rejects_the_previous_version() {
    // Elixir migrates 0.1 specs before rendering; the renderer only reads the current format.
    let mut spec = minimal();
    spec["spec_version"] = json!("0.1");
    let err = parse(&spec).unwrap_err();
    assert!(err.to_string().contains("spec_version"), "{err}");
}

#[test]
fn spec_accepts_an_image_prompt() {
    let mut spec = minimal();
    spec["scenes"][0]["intent"]["image_prompt"] = json!("A dim room, vertical shot.");
    let parsed = parse(&spec).expect("image_prompt is part of the intent");
    assert_eq!(
        parsed.scenes[0].intent.image_prompt.as_deref(),
        Some("A dim room, vertical shot.")
    );
}
```

- [ ] **Step 3: Run and see them fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/spec_test.exs 2>&1 | tail -15
cd .. && cargo test -p retake_render --test spec 2>&1 | tail -15
```
Expected: Elixir failures (`Spec.migrate/1` undefined; examples still say 0.1 so the example test and the 0.2 expectations fail); Rust: `spec_accepts_an_image_prompt` fails (unknown field), `spec_accepts_every_example` is still green for now.

- [ ] **Step 4: Bump the data files.** From the repo root:

```bash
sed -i 's/"spec_version": "0.1"/"spec_version": "0.2"/' spec/examples/minimal.json spec/examples/explainer.json fixtures/specs/minimal.json fixtures/specs/cuts.json fixtures/specs/multi.json
grep -n '"spec_version"' spec/examples/*.json fixtures/specs/*.json
```
Expected: five lines, all `"0.2"`. (`sed` is safe here: the pattern is exact and the files are tracked, so `git diff` shows the five one-line changes.)

- [ ] **Step 5: Edit the schema.** In `spec/video.schema.json`: line 10 becomes `"spec_version": { "const": "0.2" },`. In the scene `intent` properties replace the `visual_query` line with these two lines:

```json
            "visual_query": { "type": "string", "maxLength": 300, "description": "Stock search terms." },
            "image_prompt": { "type": "string", "maxLength": 600, "description": "What an image generator should paint for this scene (added in 0.2). Used when the profile has an image provider; visual_query is the stock fallback." },
```

- [ ] **Step 6: Edit `spec/SPEC.md`.**
  - Line 1: `# Retake video spec v0.2`.
  - Lines 18-20: change `(narration,\n   visual search terms, on-screen text)` to `(narration,\n   stock search terms, an image prompt, on-screen text)`.
  - Line 85: change the row to `| 2. Visual per scene: a generated image, else stock search | \`assets\` (image/video), \`scenes[].visual\`, \`scenes[].intent.image_prompt\` |`.
  - Before `## Deliberately not in v0`, add:

```markdown
## Versions

- **0.2**: adds the optional `scenes[].intent.image_prompt`, the generation prompt for AI
  images. A 0.1 spec is a valid 0.2 spec apart from its version string; `Retake.Spec.migrate/1`
  changes it on load. The renderer reads only the current version.
- **0.1**: the first format.
```
  - In the "Deliberately not in v0" list change `- Generated images or video (stock only), avatars, lip sync` to `- Generated video, avatars, lip sync (generated images arrived in 0.2)`.

- [ ] **Step 7: Edit `api/lib/retake/spec.ex`.** Add `@current_version "0.2"` under the aliases, `migrate/1`, and call it in `validate/1`:

```elixir
  @current_version "0.2"

  @doc """
  Brings a spec written for an older format up to the current one: a 0.1 spec only needs its
  version changed (0.2 added an optional field). Anything else is returned as it is.
  """
  @spec migrate(term()) :: term()
  def migrate(%{"spec_version" => "0.1"} = spec), do: Map.put(spec, "spec_version", @current_version)
  def migrate(spec), do: spec

  @doc "Validates a decoded spec (migrated first). Returns every error found, not just the first."
  @spec validate(term()) :: {:ok, t()} | {:error, [error()]}
  def validate(spec) do
    spec = migrate(spec)

    with :ok <- Schema.validate(spec),
         [] <- Rules.check(spec) do
      {:ok, spec}
    else
      {:error, errors} -> {:error, errors}
      errors when is_list(errors) -> {:error, errors}
    end
  end
```
(Replace the existing `@doc`/`@spec`/`validate/1`; keep `load/1`, `error/3` and the private functions.) In the moduledoc add: `A spec written for an older version is migrated first (\`migrate/1\`), so \`validate/1\` and \`load/1\` return the current format.`

- [ ] **Step 8: Edit `assemble.ex` line 91:** `"spec_version" => "0.2",`.

- [ ] **Step 9: Edit the Rust parser.** In `crates/retake_render/src/spec.rs`: line 16 `pub const SUPPORTED_VERSION: &str = "0.2";` and in `Intent` (line 97-101):

```rust
pub struct Intent {
    pub narration: String,
    pub visual_query: String,
    pub image_prompt: Option<String>,
    pub on_screen_text: Option<String>,
}
```

- [ ] **Step 10: Run and see everything pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/spec_test.exs test/retake/fixtures_test.exs test/retake/pipeline/assemble_test.exs test/retake/render_test.exs 2>&1 | tail -8
cd .. && cargo test -p retake_render 2>&1 | tail -8 && bash scripts/verify-fixtures.sh 2>&1 | tail -3
```
Expected: `0 failures`; cargo: all `test result: ok`; verify-fixtures prints its usual success line.

- [ ] **Step 11: Hand over the commit (User runs)**

```bash
cd api && mix format && cd .. && cargo fmt --all
git add spec/ fixtures/specs/ api/lib/retake/spec.ex api/lib/retake/pipeline/assemble.ex crates/retake_render/src/spec.rs crates/retake_render/tests/spec.rs api/test/retake/spec_test.exs api/test/retake/pipeline/assemble_test.exs api/test/retake/render_test.exs
git commit -m "feat(spec): 0.2 adds intent.image_prompt, with a 0.1 migration" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The script step writes an `image_prompt` per scene

**Files:**
- Modify: `api/lib/retake/pipeline/script.ex` (schema at line 41-45, type at 52-56, `clean_scene` at 252-272, prompt at 339-357)
- Modify: `api/lib/mix/tasks/retake.script.ex` (lines 99-103, 112-115)
- Test: `api/test/retake/pipeline/script_test.exs`

**Interfaces:**
- Consumes: spec 0.2 (Task 5).
- Produces: each scene from `Script.generate/3` is `%{narration, visual_query, image_prompt :: String.t() | nil, on_screen_text}`. `image_prompt` is optional in the model's reply; blank means `nil`.

- [ ] **Step 1: Write the failing tests.** In `script_test.exs`, inside `describe "generate/3"` after the `"keeps on_screen_text..."` test, add:

```elixir
    test "keeps image_prompt when given, and makes it nil when blank or missing", %{client: client} do
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

    test "an image_prompt over 600 characters is rejected and the reply retried", %{client: client} do
      too_long = [scene(1, %{"image_prompt" => String.duplicate("a", 601)}), scene(2), scene(3)]
      replies([reply(script_json(too_long)), reply(script_json())])

      assert {:ok, %{scenes: scenes}} = Script.generate(client, @brief)
      assert length(scenes) == 3
      assert length(requests()) == 2
    end

    test "the prompt asks for an image_prompt in every scene", %{client: client} do
      replies([reply(script_json())])
      {:ok, _} = Script.generate(client, @brief)

      [request] = requests()
      system = request["messages"] |> hd() |> Map.fetch!("content")
      assert system =~ ~s("image_prompt")
      assert system =~ "vertical composition"
    end
```
Also, in the existing first test (`"returns the title and the scenes"`) the pattern `%{narration: ..., visual_query: ..., on_screen_text: nil} = hd(scenes)` still matches (maps match partially): leave it.

- [ ] **Step 2: Run and see them fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline/script_test.exs 2>&1 | tail -15
```
Expected: 3 failures (`first.image_prompt` is a `KeyError`; the 601-character reply is accepted so only 1 request is made; the prompt text lacks `image_prompt`).

- [ ] **Step 3: Edit `script.ex`.**
  - In `@schema` scene `properties` add, between `visual_query` and `on_screen_text`:
    `"image_prompt" => %{"type" => "string", "maxLength" => 600},` (not in `required`).
  - In `@type scene` add `image_prompt: String.t() | nil,` after `visual_query`.
  - Replace `clean_scene/1`:

```elixir
  defp clean_scene(scene) do
    narration = String.trim(scene["narration"])
    visual_query = String.trim(scene["visual_query"])

    cond do
      narration == "" ->
        {:error, "narration must not be blank"}

      visual_query == "" ->
        {:error, "visual_query must not be blank"}

      true ->
        {:ok,
         %{
           narration: narration,
           visual_query: visual_query,
           image_prompt: trimmed(scene["image_prompt"]),
           on_screen_text: trimmed(scene["on_screen_text"])
         }}
    end
  end

  # Optional text: nil when absent or blank, trimmed otherwise.
  defp trimmed(nil), do: nil
  defp trimmed(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))
```
  - In `messages/1`: the reply-shape line becomes
    `{"title": "...", "scenes": [{"narration": "...", "visual_query": "...", "image_prompt": "...", "on_screen_text": "..."}]}`
    and after the `visual_query` rule add:

```
    - image_prompt: one or two English sentences describing the picture an image generator should \
    paint for this scene: the subject, the setting and the light, in a vertical composition with the \
    subject in the centre. Concrete and visual. No text, logos, brands or real people's names.
```

- [ ] **Step 4: Edit `retake.script.ex`.** After line 101 (`shell.info("   visual: ...")`) add:

```elixir
      if scene.image_prompt, do: shell.info("   image:  #{scene.image_prompt}")
```
and replace `scene_json/1` with:

```elixir
  defp scene_json(scene) do
    %{"narration" => scene.narration, "visual_query" => scene.visual_query}
    |> put_if("image_prompt", scene.image_prompt)
    |> put_if("on_screen_text", scene.on_screen_text)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
```

- [ ] **Step 5: Run and see them pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline/script_test.exs 2>&1 | tail -6
```
Expected: `0 failures`.

- [ ] **Step 6: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/pipeline/script.ex api/lib/mix/tasks/retake.script.ex api/test/retake/pipeline/script_test.exs
git commit -m "feat(api): script step writes an image prompt per scene" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
Note for the user: the script prompt changed, so the first `just script` after this is a cache miss (a new request) and uses one Groq call.

---

### Task 7: `Retake.Pipeline.Images`: one cached image call becomes a spec asset

**Files:**
- Create: `api/lib/retake/pipeline/images.ex`
- Test: `api/test/retake/pipeline/images_test.exs`

**Interfaces:**
- Consumes: `Retake.Providers.Client.call/4` (capability `:image`), `Retake.Cache.Entry.provenance/1`, `Retake.Storage.fetch/2`, `Retake.Media.Image.dimensions/1`, `Retake.Test.Images.jpeg/2`.
- Produces: `Retake.Pipeline.Images.generate(Client.t(), %{image_prompt: String.t()}) :: {:ok, %{asset: map(), prompt: String.t(), warnings: [String.t()]}} | {:error, term()}`. Errors pass through from `Client.call` (`{:all_providers_failed, _}`, `{:budget_exceeded, _}`, `{:capability_not_configured, :image}`), plus `{:bad_image, reason}` and `{:unexpected_image_result, result}`. The asset has `"kind" => "image"`, `"uri"`, `"content_hash"`, `"media" => %{"width", "height", "mime"}`, `"provenance"` (source `"generated"`), `"license" => %{"name" => "AI-generated: <model>"}`.

- [ ] **Step 1: Write the failing test**

`api/test/retake/pipeline/images_test.exs`:

```elixir
defmodule Retake.Pipeline.ImagesTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Images
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage
  alias Retake.Storage.Local
  alias Retake.Test.Images, as: TestImages

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "l", fallbacks = [] }
  tts = { use = "t", fallbacks = [] }
  stt = { use = "s", fallbacks = [] }
  stock = { use = "k", fallbacks = [] }
  music = { use = "m", fallbacks = [] }
  image = { use = "painter", fallbacks = [] }

  [providers.painter]
  capability = "image"
  adapter = "fake"
  model = "flux-test"

  [providers.l]
  capability = "llm"
  adapter = "fake"

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

  @scene %{
    narration: "Your phone is the last thing you see at night.",
    visual_query: "phone bed dark",
    image_prompt: "A dim bedroom at night, a phone glowing on a pillow, vertical shot."
  }

  setup %{tmp_dir: dir} do
    %{client: client(dir, @config), dir: dir}
  end

  defp client(dir, toml) do
    {:ok, config} = Config.parse(toml)

    Client.new(
      config: config,
      profile: "dev",
      storage: Local.new(Path.join(dir, "store")),
      cache_root: Path.join(dir, "cache"),
      usage: start_supervised!(Usage, id: make_ref())
    )
  end

  defp paint(answer) do
    Process.put(:fake_adapter_answers, %{"painter" => answer})
  end

  defp image(bytes), do: {:ok, {:binary, bytes, "jpg"}, %{cost_usd: 0.0, units: %{"steps" => 4}}}

  defp painter_calls do
    receive do
      {:adapter_called, "painter", _key, request} -> [request | painter_calls()]
    after
      0 -> []
    end
  end

  describe "generate/2" do
    test "returns a spec asset for the stored image", %{client: client} do
      bytes = TestImages.jpeg(1080, 1920)
      paint(image(bytes))

      assert {:ok, %{asset: asset, prompt: prompt, warnings: []}} = Images.generate(client, @scene)

      assert prompt == @scene.image_prompt
      assert asset["kind"] == "image"
      assert asset["media"] == %{"width" => 1080, "height" => 1920, "mime" => "image/jpeg"}
      assert asset["content_hash"] == Storage.content_hash(bytes)
      assert "store://assets/" <> _ = asset["uri"]
      assert asset["license"] == %{"name" => "AI-generated: flux-test"}
    end

    test "the provenance says generated, by whom, with what request", %{client: client} do
      paint(image(TestImages.jpeg(1080, 1920)))
      {:ok, %{asset: asset}} = Images.generate(client, @scene)

      assert %{
               "source" => "generated",
               "capability" => "image",
               "provider" => "painter",
               "model" => "flux-test",
               "request" => %{"prompt" => "A dim bedroom" <> _},
               "request_hash" => "sha256:" <> _,
               "cost" => %{"amount" => amount, "currency" => "USD"}
             } = asset["provenance"]

      assert amount == 0.0
    end

    test "the bytes are in storage", %{client: client, dir: dir} do
      bytes = TestImages.jpeg(1080, 1920)
      paint(image(bytes))
      {:ok, %{asset: asset}} = Images.generate(client, @scene)

      assert Storage.fetch(Local.new(Path.join(dir, "store")), asset["uri"]) == {:ok, bytes}
    end

    test "warns when the image is not portrait", %{client: client} do
      paint(image(TestImages.jpeg(1024, 1024)))
      assert {:ok, %{warnings: [warning]}} = Images.generate(client, @scene)
      assert warning =~ "1024x1024"
      assert warning =~ "not portrait"
    end

    test "a repeat is answered from the cache: the provider is called once", %{client: client} do
      paint(image(TestImages.jpeg(1080, 1920)))

      {:ok, first} = Images.generate(client, @scene)
      {:ok, second} = Images.generate(client, @scene)

      assert first.asset == second.asset
      assert [%{"prompt" => _}] = painter_calls()
    end

    test "a provider failure is returned as the provider layer reports it", %{client: client} do
      paint({:error, {:http, 503, "overloaded"}})

      assert {:error, {:all_providers_failed, [%{provider: "painter", reason: {:http, 503, _}}]}} =
               Images.generate(client, @scene)
    end

    test "a reply that is not an image is an error and is not cached", %{client: client} do
      paint(image("<html>please log in</html>"))
      assert {:error, {:bad_image, :unknown_format}} = Images.generate(client, @scene)
    end

    test "a profile with no image slot", %{dir: dir} do
      toml = String.replace(@config, ~s(image = { use = "painter", fallbacks = [] }\n), "")

      assert {:error, {:capability_not_configured, :image}} =
               Images.generate(client(dir, toml), @scene)
    end
  end
end
```

Note on the "not an image ... not cached" test: `Client.call` stores whatever the adapter returns, so a non-image from a real provider is cached before `Images` can look at it. The real adapter rejects non-images itself (Task 3), so a fake adapter returning junk is the only way to reach this branch. The test pins the step's own check; it deliberately does not claim the cache is clean for fakes.

- [ ] **Step 2: Run and see it fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline/images_test.exs 2>&1 | tail -10
```
Expected: compile error, `Retake.Pipeline.Images.generate/2 is undefined`.

- [ ] **Step 3: Write the implementation**

`api/lib/retake/pipeline/images.ex`:

```elixir
defmodule Retake.Pipeline.Images do
  @moduledoc """
  A scene's `image_prompt` becomes a generated image, stored and ready to use as a spec asset.
  Nothing here knows which service paints it: one provider call for the `image` capability,
  cached by the request (the same prompt is never painted, or paid for, twice).

  The asset's size is read from the stored bytes, and its provenance (source `generated`, the
  provider, the model, the prompt, the cost) comes from the cache entry, so the spec says how
  every picture was made (AGENTS.md rule 4). A picture that is not portrait is still usable, but
  the video is 9:16 and the renderer fits it with `cover`, so its sides are cropped: that is
  reported as a warning.

  Talks to providers only through `Retake.Providers.Client`.
  """

  alias Retake.Cache.Entry
  alias Retake.Media.Image
  alias Retake.Providers.Client
  alias Retake.Storage

  @type generated :: %{asset: map(), prompt: String.t(), warnings: [String.t()]}

  @doc """
  Makes the image for `scene` (a map with an `:image_prompt`, as `Retake.Pipeline.Script`
  returns it).

  Returns `{:ok, %{asset: asset, prompt: prompt, warnings: warnings}}` where `asset` is a spec
  asset (string keys), or an error: what `Retake.Providers.Client.call/4` returns
  (`{:all_providers_failed, _}`, `{:budget_exceeded, _}`, `{:capability_not_configured, :image}`),
  `{:bad_image, reason}` when the stored bytes are not an image, or
  `{:unexpected_image_result, result}`.
  """
  @spec generate(Client.t(), %{required(:image_prompt) => String.t(), optional(atom()) => term()}) ::
          {:ok, generated()} | {:error, term()}
  def generate(%Client{} = client, %{image_prompt: prompt}) when is_binary(prompt) do
    case Client.call(client, :image, %{"prompt" => prompt}) do
      {:ok, %Entry{result: {:asset, ref}} = entry, _outcome} -> describe(client, entry, ref, prompt)
      {:ok, entry, _outcome} -> {:error, {:unexpected_image_result, entry.result}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp describe(client, entry, ref, prompt) do
    with {:ok, bytes} <- Storage.fetch(client.storage, ref.uri),
         {:ok, info} <- dimensions(bytes) do
      {:ok, %{asset: asset(entry, ref, info), prompt: prompt, warnings: warnings(info)}}
    end
  end

  defp dimensions(bytes) do
    case Image.dimensions(bytes) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, {:bad_image, reason}}
    end
  end

  defp asset(entry, ref, info) do
    %{
      "kind" => "image",
      "uri" => ref.uri,
      "content_hash" => ref.content_hash,
      "media" => %{"width" => info.width, "height" => info.height, "mime" => info.mime},
      "provenance" => Entry.provenance(entry),
      "license" => %{"name" => "AI-generated: #{entry.model}"}
    }
  end

  defp warnings(%{width: width, height: height}) when width >= height do
    [
      "the image is #{width}x#{height}, not portrait: the video crops its sides to fit 9:16"
    ]
  end

  defp warnings(_info), do: []
end
```

- [ ] **Step 4: Run and see it pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline/images_test.exs 2>&1 | tail -6
bash ../scripts/check-boundaries.sh
```
Expected: `0 failures` (8 tests) and `boundaries ok`.

- [ ] **Step 5: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/pipeline/images.ex api/test/retake/pipeline/images_test.exs
git commit -m "feat(api): images step turns an image prompt into a spec asset" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `Retake.Pipeline.Visuals`: generated first, stock as the fallback

**Files:**
- Create: `api/lib/retake/pipeline/visuals.ex`
- Test: `api/test/retake/pipeline/visuals_test.exs`

**Interfaces:**
- Consumes: `Retake.Pipeline.Images.generate/2`, `Retake.Pipeline.Stock.find/3`, `Retake.CLI.describe/2`.
- Produces: `Retake.Pipeline.Visuals.find(Client.t(), scene, stock_opts \\ []) :: {:ok, %{asset: map(), query: String.t(), source: :generated | :stock, prompt: String.t() | nil, warnings: [String.t()]}} | {:error, term()}` where `scene` is `%{narration, visual_query, image_prompt (optional key)}`. The error case is only `Stock.find`'s error (`{:no_stock_found, queries}` or a provider error): an image failure never fails the scene.

- [ ] **Step 1: Write the failing test**

`api/test/retake/pipeline/visuals_test.exs`:

```elixir
defmodule Retake.Pipeline.VisualsTest do
  use ExUnit.Case, async: true

  alias Retake.Pipeline.Visuals
  alias Retake.Providers.{Client, Config, Usage}
  alias Retake.Storage.Local
  alias Retake.Test.Images, as: TestImages

  @moduletag :tmp_dir

  @config """
  [retake]
  default_profile = "dev"

  [profiles.dev]
  llm = { use = "l", fallbacks = [] }
  tts = { use = "t", fallbacks = [] }
  stt = { use = "s", fallbacks = [] }
  stock = { use = "stock", fallbacks = [] }
  music = { use = "m", fallbacks = [] }
  image = { use = "painter", fallbacks = [] }

  [providers.painter]
  capability = "image"
  adapter = "fake"
  model = "flux-test"

  [providers.stock]
  capability = "stock"
  adapter = "fake"

  [providers.l]
  capability = "llm"
  adapter = "fake"

  [providers.t]
  capability = "tts"
  adapter = "fake"

  [providers.s]
  capability = "stt"
  adapter = "fake"

  [providers.m]
  capability = "music"
  adapter = "fake"
  """

  @scene %{
    narration: "Your phone is the last thing you see at night.",
    visual_query: "phone bed dark",
    image_prompt: "A dim bedroom at night, a phone glowing on a pillow, vertical shot."
  }

  setup %{tmp_dir: dir} do
    %{client: client(dir, @config), dir: dir}
  end

  defp client(dir, toml) do
    {:ok, config} = Config.parse(toml)

    Client.new(
      config: config,
      profile: "dev",
      storage: Local.new(Path.join(dir, "store")),
      cache_root: Path.join(dir, "cache"),
      usage: start_supervised!(Usage, id: make_ref())
    )
  end

  # A fake stock service that finds one portrait photo for any query.
  defp stock_answer do
    candidate = %{
      "kind" => "photo",
      "id" => 1,
      "page_url" => "https://stock.test/p/1",
      "creator" => "P. Hotographer",
      "duration_ms" => nil,
      "source" => "Pexels",
      "license" => %{"name" => "Pexels License"},
      "files" => [
        %{"url" => "https://cdn.test/p1.jpg", "width" => 1080, "height" => 1920, "mime" => "image/jpeg"}
      ]
    }

    fn
      %{"action" => "search", "kind" => "video"} -> {:ok, {:json, %{"results" => []}}, %{}}
      %{"action" => "search", "kind" => "photo"} -> {:ok, {:json, %{"results" => [candidate]}}, %{}}
      %{"action" => "download"} -> {:ok, {:binary, "photo bytes", "jpg"}, %{}}
    end
  end

  defp serve(painter) do
    Process.put(:fake_adapter_answers, %{"painter" => painter, "stock" => stock_answer()})
  end

  defp portrait, do: {:ok, {:binary, TestImages.jpeg(1080, 1920), "jpg"}, %{cost_usd: 0.0, units: %{}}}

  defp called(provider) do
    receive do
      {:adapter_called, ^provider, _key, request} -> [request | called(provider)]
    after
      0 -> []
    end
  end

  describe "find/3 with an image provider and an image_prompt" do
    test "generates the image and does not touch stock", %{client: client} do
      serve(portrait())

      assert {:ok, found} = Visuals.find(client, @scene)

      assert found.source == :generated
      assert found.prompt == @scene.image_prompt
      assert found.query == "phone bed dark"
      assert found.warnings == []
      assert found.asset["kind"] == "image"
      assert found.asset["provenance"]["source"] == "generated"
      assert called("stock") == []
    end

    test "keeps the image's own warnings (a square image)", %{client: client} do
      serve({:ok, {:binary, TestImages.jpeg(1024, 1024), "jpg"}, %{}})
      assert {:ok, %{source: :generated, warnings: [warning]}} = Visuals.find(client, @scene)
      assert warning =~ "not portrait"
    end
  end

  describe "find/3 falls back to stock" do
    test "when the scene has no image_prompt", %{client: client} do
      serve(portrait())

      assert {:ok, found} = Visuals.find(client, Map.delete(@scene, :image_prompt))

      assert found.source == :stock
      assert found.prompt == nil
      assert found.warnings == []
      assert found.asset["provenance"]["source"] == "stock"
      assert called("painter") == []
    end

    test "when the image_prompt is nil or blank", %{client: client} do
      serve(portrait())

      for blank <- [nil, "", "   "] do
        assert {:ok, %{source: :stock}} = Visuals.find(client, %{@scene | image_prompt: blank})
      end

      assert called("painter") == []
    end

    test "when the profile has no image slot, with no warning", %{dir: dir} do
      toml = String.replace(@config, ~s(image = { use = "painter", fallbacks = [] }\n), "")
      serve(portrait())

      assert {:ok, %{source: :stock, warnings: []}} = Visuals.find(client(dir, toml), @scene)
      assert called("painter") == []
    end

    test "with a warning when the image could not be made", %{client: client} do
      serve({:error, {:http, 503, "overloaded"}})

      assert {:ok, %{source: :stock, prompt: nil, warnings: [warning]}} = Visuals.find(client, @scene)

      assert warning =~ "the image could not be made"
      assert warning =~ "overloaded"
      assert warning =~ "stock footage used instead"
      refute warning =~ "\n"
    end

    test "with a warning when the image provider returns something that is not an image", %{client: client} do
      serve({:ok, {:binary, "<html>nope</html>", "jpg"}, %{}})
      assert {:ok, %{source: :stock, warnings: [warning]}} = Visuals.find(client, @scene)
      assert warning =~ "the image could not be made"
    end

    test "with no warning when the image provider has no key", %{dir: dir} do
      toml =
        String.replace(
          @config,
          ~s([providers.painter]\ncapability = "image"),
          ~s([providers.painter]\ncapability = "image"\napi_key_env = "RETAKE_TEST_NO_SUCH_KEY")
        )

      serve(portrait())

      assert {:ok, %{source: :stock, warnings: []}} = Visuals.find(client(dir, toml), @scene)
      assert called("painter") == []
    end
  end

  describe "find/3 when stock fails too" do
    test "returns the stock error, not the image error", %{client: client} do
      Process.put(:fake_adapter_answers, %{
        "painter" => {:error, {:http, 503, "overloaded"}},
        "stock" => fn %{"action" => "search"} -> {:ok, {:json, %{"results" => []}}, %{}} end
      })

      assert {:error, {:no_stock_found, _queries}} = Visuals.find(client, @scene)
    end
  end
end
```

- [ ] **Step 2: Run and see it fail (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline/visuals_test.exs 2>&1 | tail -10
```
Expected: compile error, `Retake.Pipeline.Visuals.find/2 is undefined`.

- [ ] **Step 3: Write the implementation**

`api/lib/retake/pipeline/visuals.ex`:

```elixir
defmodule Retake.Pipeline.Visuals do
  @moduledoc """
  Step 2 of the pipeline: the picture for a scene. A generated image when the profile has an
  image provider and the scene has an `image_prompt` (`Retake.Pipeline.Images`); stock footage
  or a photo otherwise (`Retake.Pipeline.Stock`).

  An image failure never fails the scene: whatever goes wrong (a refusal, a rate limit, a spent
  budget, a bad reply), the scene falls back to stock, with a warning saying why. The two cases
  that are a choice, not a failure, fall back silently: the profile has no image provider, or
  the provider has no API key set (a user with no Cloudflare account should not see a warning
  on every scene).

  Returns the same shape the stock step does, plus where the picture came from:

      %{asset: spec_asset, query: "...", source: :generated | :stock,
        prompt: "..." | nil, warnings: [...]}

  Talks to providers only through `Retake.Providers.Client` (via the two steps it joins).
  """

  alias Retake.CLI
  alias Retake.Pipeline.{Images, Stock}
  alias Retake.Providers.Client

  @type found :: %{
          asset: map(),
          query: String.t(),
          source: :generated | :stock,
          prompt: String.t() | nil,
          warnings: [String.t()]
        }

  @doc """
  Finds or makes the picture for `scene` (`%{narration, visual_query}` and optionally
  `image_prompt`, as `Retake.Pipeline.Script` returns them). `stock_opts` go to
  `Retake.Pipeline.Stock.find/3`.

  Returns `{:ok, found}`, or the stock step's error (`{:no_stock_found, queries}` or a provider
  error) when no picture could be had at all.
  """
  @spec find(Client.t(), map(), keyword()) :: {:ok, found()} | {:error, term()}
  def find(%Client{} = client, scene, stock_opts \\ []) do
    case Map.get(scene, :image_prompt) do
      prompt when is_binary(prompt) ->
        if String.trim(prompt) == "" do
          stock(client, scene, stock_opts, [])
        else
          generated_or_stock(client, scene, stock_opts)
        end

      _none ->
        stock(client, scene, stock_opts, [])
    end
  end

  defp generated_or_stock(client, scene, stock_opts) do
    case Images.generate(client, scene) do
      {:ok, %{asset: asset, prompt: prompt, warnings: warnings}} ->
        {:ok,
         %{
           asset: asset,
           query: scene.visual_query,
           source: :generated,
           prompt: prompt,
           warnings: warnings
         }}

      {:error, reason} ->
        stock(client, scene, stock_opts, fallback_warnings(reason))
    end
  end

  defp stock(client, scene, stock_opts, warnings) do
    with {:ok, found} <- Stock.find(client, scene, stock_opts) do
      {:ok,
       %{
         asset: found.asset,
         query: found.query,
         source: :stock,
         prompt: nil,
         warnings: warnings ++ found.warnings
       }}
    end
  end

  # Not configured, or configured without a key: stock only, nothing to say.
  defp fallback_warnings({:capability_not_configured, :image}), do: []

  defp fallback_warnings({:all_providers_failed, attempts} = reason) do
    if Enum.all?(attempts, &match?(%{reason: {:missing_env, _}}, &1)),
      do: [],
      else: [warning(reason)]
  end

  defp fallback_warnings(reason), do: [warning(reason)]

  defp warning(reason) do
    why = reason |> CLI.describe(nil) |> String.replace(~r/\s+/, " ") |> String.trim()
    "the image could not be made (#{why}); stock footage used instead"
  end
end
```

- [ ] **Step 4: Run and see it pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline/visuals_test.exs 2>&1 | tail -6
bash ../scripts/check-boundaries.sh
```
Expected: `0 failures` (9 tests) and `boundaries ok`.

- [ ] **Step 5: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/pipeline/visuals.ex api/test/retake/pipeline/visuals_test.exs
git commit -m "feat(api): visuals step: generated image first, stock as the fallback" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Wire `Visuals` into the pipeline (`:stock` event becomes `:visual`)

**Files:**
- Modify: `api/lib/retake/pipeline.ex` (aliases line 37, moduledoc lines 5-12 and 22, `prepare/5` 118-146, `stock_detail` 188-190, `scene_warnings` 225-229)
- Modify: `api/lib/retake/pipeline/assemble.ex` (moduledoc line 12, `assets/1` line 121, `scene/1` line 133, `intent/1` lines 140-143)
- Modify: `api/lib/mix/tasks/retake.video.ex` (line 135-136)
- Modify: `api/test/support/scripted_adapter.ex`
- Test: `api/test/retake/pipeline_test.exs`, `api/test/retake/pipeline/assemble_test.exs`, `api/test/retake/videos/runner_test.exs`

**Interfaces:**
- Consumes: `Retake.Pipeline.Visuals.find/3` (Task 8), spec 0.2 (Task 5).
- Produces: pipeline event `%{step: :visual, scene: n, status: :done, kind: "image" | "video", source: :generated | :stock, query: String.t(), credit?: String.t(), prompt?: String.t()}` (nil keys are left out); `Assemble.build/1` input scenes are `%{visual: %{asset, query, source, prompt, warnings}, voice: ...}`; the spec's `scenes[].intent.image_prompt` is set when the script scene has one.

- [ ] **Step 1: Extend the scripted test adapter.** In `api/test/support/scripted_adapter.ex`:
  - In the moduledoc role list add: `* "image": "paints" the fixture photo \`gradient.jpg\` (1350x2400) for any prompt;` and, in the `llm` bullet, note that scene 2 carries an `image_prompt`.
  - In `@script`, give the second scene an image prompt:
    `%{"narration" => "It is full of antioxidants.", "visual_query" => "photo gradient leaves", "image_prompt" => "A calm sea at sunrise, vertical shot, soft light."},`
  - Add a clause before the final catch-all `answer/4`:

```elixir
  defp answer("image", _provider, %{"prompt" => _prompt}, _context) do
    {:ok, {:binary, File.read!(Path.join(@fixtures, "gradient.jpg")), "jpg"},
     %{cost_usd: 0.0, units: %{"steps" => 4}}}
  end
```

- [ ] **Step 2: Update the existing pipeline tests, then add the new ones.** In `api/test/retake/pipeline_test.exs`:
  - In `toml/2`: add a line inside `[profiles.test]` after `music = ...`: `#{opt.("image_slot", "")}`; and add a provider block after `[providers.stock]`:

```
    [providers.painter]
    capability = "image"
    adapter = "scripted"
    role = "image"
    model = "scripted-flux"
    log = "#{log}"
    #{opt.("painter", "")}
```
  - Near `@brief` add `@painter %{"image_slot" => ~s(image = { use = "painter", fallbacks = [] })}`.
  - Replace `:stock` with `:visual` at the event assertions: lines 229, 230, 237, 239 (`find(events, :stock, ...)`), the lists at 264 and 269 (`[:stock, :voice]`), the refute list at 293 (`[:stock, :voice, :assemble, :render]`), and line 300 (`step: :stock` to `step: :visual`) and 306 (`find(events, :stock, 3, :failed)`). Rename the test at line 297 to `"footage not found for a scene fails that scene's visual step"`.
  - Add a new describe at the end of the module:

```elixir
  describe "run/3: generated images" do
    defp sources(spec) do
      Enum.map(spec["scenes"], &spec["assets"][&1["visual"]["asset"]]["provenance"]["source"])
    end

    test "a scene with an image_prompt gets a generated image, the others stay stock", %{tmp_dir: dir} do
      assert {:ok, %{spec: spec, output: output}} = run(client(dir, @painter), dir)

      assert sources(spec) == ["stock", "generated", "stock"]
      assert {:ok, _} = Spec.validate(spec)
      assert Enum.at(spec["scenes"], 1)["intent"]["image_prompt"] =~ "calm sea"
      assert hd(spec["scenes"])["intent"]["image_prompt"] == nil
      assert File.stat!(output).size > 0
    end

    test "the visual events say where each picture came from", %{tmp_dir: dir} do
      {:ok, _} = run(client(dir, @painter), dir)
      events = events()

      assert %{source: :generated, kind: "image", prompt: prompt} = find(events, :visual, 2, :done)
      assert prompt =~ "calm sea"
      refute Map.has_key?(find(events, :visual, 2, :done), :credit)
      assert %{source: :stock, kind: "video", credit: _} = find(events, :visual, 1, :done)
    end

    test "a failing image provider falls back to stock, with a warning", %{tmp_dir: dir} do
      client = client(dir, Map.put(@painter, "painter", "fail = true"))

      assert {:ok, %{spec: spec, warnings: warnings}} = run(client, dir)

      assert sources(spec) == ["stock", "stock", "stock"]
      assert Enum.any?(warnings, &(&1 =~ "scene 2" and &1 =~ "stock footage used instead"))
    end

    test "with no image slot every scene is stock and nothing warns about images", %{tmp_dir: dir} do
      assert {:ok, %{spec: spec, warnings: warnings}} = run(client(dir), dir)

      assert sources(spec) == ["stock", "stock", "stock"]
      refute Enum.any?(warnings, &(&1 =~ "image"))
      refute Enum.any?(calls(dir), &String.starts_with?(&1, "painter"))
    end
  end
```
  (`defp` inside `describe` is fine in ExUnit; if the formatter or compiler objects, move `sources/1` next to the other helpers.)

- [ ] **Step 3: Update `runner_test.exs`.** In `api/test/retake/videos/runner_test.exs` change the progress keys the pipeline now reports: line 91 `steps["stock"]` to `steps["visual"]`, line 95 `["1"]["stock"]["kind"]` to `["1"]["visual"]["kind"]`, line 109 `"step" => "stock"` to `"step" => "visual"`, line 155 `"step" => "stock"` to `"step" => "visual"`, line 159 `["3"]["stock"]` to `["3"]["visual"]`. Do **not** touch line 150 (`%{"stock" => ~s(empty_for = "sea")}` is a provider name) or line 156 (message text).

- [ ] **Step 4: Update `assemble_test.exs` and add tests.** In `api/test/retake/pipeline/assemble_test.exs`:
  - line 89: `stock: %{asset: stock_asset(n, kind), query: "query #{n}", warnings: []},` becomes
    `visual: %{asset: stock_asset(n, kind), query: "query #{n}", source: :stock, prompt: nil, warnings: []},`
  - Add at the end of `describe "build/1"`:

```elixir
    test "puts the script's image_prompt in the scene intent, and leaves it out when there is none" do
      scenes = [
        script_scene(1) |> Map.put(:image_prompt, "A dim room, vertical shot."),
        script_scene(2) |> Map.put(:image_prompt, nil),
        script_scene(3)
      ]

      input = input(["image", "image", "image"], %{script: %{title: "Tea facts", scenes: scenes}})
      {spec, _} = build!(input)

      assert Enum.at(spec["scenes"], 0)["intent"]["image_prompt"] == "A dim room, vertical shot."
      refute Map.has_key?(Enum.at(spec["scenes"], 1)["intent"], "image_prompt")
      refute Map.has_key?(Enum.at(spec["scenes"], 2)["intent"], "image_prompt")
      assert {:ok, _} = Spec.validate(spec)
    end
```

- [ ] **Step 5: Run and see the failures (User runs)**

```bash
(cd .. && cargo build -p retake_render 2>&1 | tail -1)
unset MIX_ENV
mix test test/retake/pipeline_test.exs test/retake/pipeline/assemble_test.exs test/retake/videos/runner_test.exs > ../.retake/test-out.txt 2>&1; tail -25 ../.retake/test-out.txt
```
Expected: failures in the three files (`Assemble` still reads `part.stock`; events are still `:stock`). The pipeline test needs the debug renderer (the `cargo build` line) and ffprobe.

- [ ] **Step 6: Edit `assemble.ex`.**
  - moduledoc line 12: `scenes: [%{visual: %{asset: ..}, voice: %{asset: .., voiceover: .., duration_ms: ..}}]`, and in the sentence below it replace `` `Retake.Pipeline.Stock.find/3` `` with `` `Retake.Pipeline.Visuals.find/3` ``; in the script line (11) add `image_prompt` to the scene keys.
  - line 121: `|> Map.put("vis-#{n}", part.visual.asset)`.
  - line 133: `"visual" => visual("vis-#{n}", part.visual.asset, n),`.
  - Replace `intent/1`:

```elixir
  defp intent(script_scene) do
    %{"narration" => script_scene.narration, "visual_query" => script_scene.visual_query}
    |> put_present("image_prompt", Map.get(script_scene, :image_prompt))
    |> put_present("on_screen_text", script_scene.on_screen_text)
  end
```

- [ ] **Step 7: Edit `pipeline.ex`.**
  - Line 37: `alias Retake.Pipeline.{Assemble, Script, Visuals, Voice}`.
  - Moduledoc: line 5 `brief --script--> scenes --(visual + voice, per scene, in parallel)--> assemble --> render`; item 2 becomes: `2. for each scene, in parallel (up to \`:concurrency\` scenes at once, and the visual and the voice step of one scene side by side): \`Retake.Pipeline.Visuals\` makes or finds the picture (a generated image, else stock footage), \`Retake.Pipeline.Voice\` makes the narration with its word timings;`; line 22 `step: :script | :visual | :voice | :assemble | :render | :brief,`; the `:done` detail sentence: `the kind of picture found and whether it was generated or stock`; the `:stock, :voice` option doc stays (`:stock` still carries `Stock.find` options).
  - Replace the `stock` task in `prepare/5`:

```elixir
  # One scene: its picture and its voice-over at the same time.
  defp prepare(client, scene, number, emit, opts) do
    visual =
      Task.async(fn ->
        step(
          :visual,
          number,
          emit,
          fn -> Visuals.find(client, scene, Keyword.get(opts, :stock, [])) end,
          &visual_detail/1
        )
      end)
```
    and replace the rest of `prepare/5` (the voice task and the `case`) with:

```elixir
    voice =
      Task.async(fn ->
        step(
          :voice,
          number,
          emit,
          fn -> Voice.generate(client, scene, Keyword.get(opts, :voice, [])) end,
          &voice_detail/1
        )
      end)

    case {Task.await(visual, :infinity), Task.await(voice, :infinity)} do
      {{:ok, visual}, {:ok, voice}} -> {:ok, %{visual: visual, voice: voice}}
      {{:error, failure}, _voice} -> {:error, failure}
      {_visual, {:error, failure}} -> {:error, failure}
    end
  end
```
  - Replace `stock_detail/1`:

```elixir
  # Credit exists only for stock; the prompt only for a generated image.
  defp visual_detail(%{asset: asset, query: query, source: source, prompt: prompt}) do
    %{
      kind: asset["kind"],
      source: source,
      query: query,
      credit: asset["license"]["attribution"],
      prompt: prompt
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
```
  - `scene_warnings/1`: `warning <- part.visual.warnings ++ part.voice.warnings,`.

- [ ] **Step 8: Edit `retake.video.ex` lines 135-136** into two clauses:

```elixir
  defp line(%{step: :visual, scene: n, status: :done, source: :generated} = e, _last),
    do: "[scene #{n}] visual:  generated #{e.kind} for #{inspect(e.prompt)}"

  defp line(%{step: :visual, scene: n, status: :done} = e, _last),
    do: "[scene #{n}] visual:  #{e.kind} for #{inspect(e.query)} (#{e.credit})"
```
  Also, in that file's `@moduledoc`, mention the image provider: after the line about needed keys add `Generated images are used when your profile has an \`image\` slot and its keys are set; otherwise stock.` (read the moduledoc first and keep its style).

- [ ] **Step 9: Run and see them pass (User runs)**

```bash
cd api && unset MIX_ENV && mix test test/retake/pipeline_test.exs test/retake/pipeline test/retake/videos test/retake_web > ../.retake/test-out.txt 2>&1; tail -8 ../.retake/test-out.txt
bash ../scripts/check-boundaries.sh
```
Expected: `0 failures`; `boundaries ok`. Paste the tail if anything fails.

- [ ] **Step 10: Hand over the commit (User runs)**

```bash
cd api && mix format && cd ..
git add api/lib/retake/pipeline.ex api/lib/retake/pipeline/assemble.ex api/lib/mix/tasks/retake.video.ex api/test/support/scripted_adapter.ex api/test/retake/pipeline_test.exs api/test/retake/pipeline/assemble_test.exs api/test/retake/videos/runner_test.exs
git commit -m "feat(api): pipeline uses the visuals step; progress event is now visual" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The web page shows "Visuals" and reads `visual` progress

**Files:**
- Modify: `web/src/lib/steps.ts` (lines 28-33, 36-42, 44-54, 77-95, 111, 117)
- Modify: `web/src/lib/scenes.ts` (line 33)
- Modify: `web/src/lib/types.ts` (lines 18-21, 35)
- Modify: `web/src/screens/Result.tsx` (line 132)
- Test: `web/test/steps.test.mjs`, `web/test/scenes.test.mjs`

**Interfaces:**
- Consumes: progress entries under `scenes[n].visual` (Task 9). Jobs saved before this change keep `scenes[n].stock`.
- Produces: `buildSteps` row key stays `footage` (no change for `Generating.tsx`), displayed as "Visuals"; it reads `visual`, else `stock`.

- [ ] **Step 1: Write the failing tests.** In `web/test/steps.test.mjs` add after the `'footage is done when every scene has its footage'` test:

```js
test('the visuals row counts scenes by their visual step', () => {
  const scenes = { 1: { visual: { status: 'done' } }, 2: { visual: { status: 'done' } }, 3: { visual: { status: 'started' } } }

  const rows = buildSteps({ status: 'running', progress: { steps: { script: scriptDone }, scenes }, error: null })

  assert.equal(rows[1].name, 'Visuals')
  assert.equal(rows[1].state, 'running')
  assert.equal(rows[1].detail, '2 of 3 pictures and clips ready')
})

test('a job saved before generated images reported its pictures as stock, and still counts', () => {
  const scenes = { 1: { stock: { status: 'done' } }, 2: { stock: { status: 'done' } }, 3: { stock: { status: 'done' } } }

  const rows = buildSteps({ status: 'running', progress: { steps: { script: scriptDone }, scenes }, error: null })

  assert.equal(rows[1].state, 'done')
})

test('a failed visual step fails the Visuals row, with the scene and the reason', () => {
  const progress = {
    steps: { script: scriptDone },
    scenes: { 3: { visual: { status: 'failed', message: 'no stock footage or photo found for: "sea"' } } },
  }
  const error = { step: 'visual', scene: 3, message: 'no stock footage or photo found for: "sea"' }

  const rows = buildSteps({ status: 'failed', progress, error })

  assert.equal(rows[1].state, 'failed')
  assert.equal(rows[1].detail, 'Scene 3: no stock footage or photo found for: "sea"')
  assert.equal(stoppedAt(error), 'Stopped at finding the visuals (scene 3)')
})
```
and in `web/test/scenes.test.mjs` add after the first `scenePlan` test:

```js
test('scenePlan reads a scene’s visual step, and the older stock step too', () => {
  const plan = scenePlan(
    {
      steps: progress.steps,
      scenes: { 1: { visual: { status: 'done' } }, 2: { stock: { status: 'done' } }, 3: { visual: { status: 'started' } } },
    },
    false,
  )

  assert.deepEqual(plan.map((scene) => scene.footage), ['done', 'done', 'running'])
})

test('credits skips generated images, which have no attribution', () => {
  const withGenerated = {
    ...spec,
    assets: { ...spec.assets, 'vis-2': { kind: 'image', license: { name: 'AI-generated: flux' } } },
  }

  assert.deepEqual(credits(withGenerated), ['Video by Ann on Pixabay'])
})
```

- [ ] **Step 2: Run and see them fail (User runs)**

```bash
cd web && npm test 2>&1 | tail -30
```
Expected: the new `visual` tests fail (`rows[1].name` is `Footage`; `visual` entries are ignored); the credits test already passes.

- [ ] **Step 3: Edit `steps.ts`.**
  - `NAMES`: `footage: 'Visuals',`.
  - `ROW_OF_STEP`: add `visual: 'footage',` above `stock: 'footage',` (keep `stock` for old jobs).
  - `STEP_WORDS`: add `visual: 'finding the visuals',` (keep `stock`).
  - Replace the head of `perScenePart`:

```ts
function perScenePart(progress: Progress, step: 'visual' | 'voice', what: string): Part {
  const entries: [string, StepEntry][] = []
  for (const [scene, steps] of Object.entries(progress.scenes ?? {})) {
    // Jobs made before generated images reported their pictures as "stock".
    const entry = steps[step] ?? (step === 'visual' ? steps.stock : undefined)
    if (entry) entries.push([scene, entry])
  }
```
  - `buildSteps`: `footage: perScenePart(progress, 'visual', 'pictures and clips ready'),`.
  - `renderPart`: `return queued('Waiting for the visuals and voice-overs')`.
  - Update the comment line 77 to `// Visuals and voice-over: one entry per scene, so count the scenes that are done.`

- [ ] **Step 4: Edit `scenes.ts` line 33:** `footage: stateOf(steps?.visual ?? steps?.stock, stopped),`.

- [ ] **Step 5: Edit `types.ts`.** Replace lines 18-21 with:

```ts
  /** Visuals: "video" or "image", where it came from ("generated" or "stock"), the search
   *  phrase, who to credit (stock only) and the image prompt (generated only). */
  kind?: string
  source?: string
  query?: string
  credit?: string
  prompt?: string
```
and the comment on line 35: `/** By scene number ("1", "2", ...), then "visual" (older jobs: "stock") and "voice". */`.

- [ ] **Step 6: Edit `Result.tsx` line 132:** `No footage to credit.` becomes `Nothing to credit.`

- [ ] **Step 7: Run and see them pass (User runs)**

```bash
cd web && npm run typecheck 2>&1 | tail -5 && npm test 2>&1 | tail -8
```
Expected: typecheck clean; `# fail 0`.

- [ ] **Step 8: Hand over the commit (User runs)**

```bash
git add web/src/lib/steps.ts web/src/lib/scenes.ts web/src/lib/types.ts web/src/screens/Result.tsx web/test/steps.test.mjs web/test/scenes.test.mjs
git commit -m "feat(web): visuals row reads the visual step, and older stock steps" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Decisions, log, feature record, and the full verification

**Files:**
- Modify: `DECISIONS.md` (append D25-D27)
- Modify: `PROGRESS.md` (append the F16 entry)
- Modify: `features.json` (F16 entry)

- [ ] **Step 1: Append the decisions to `DECISIONS.md`:**

```markdown

## D25. The `image` capability is optional in a profile, and its presence means "generated first, stock as the fallback"
A profile with an `image` slot makes an image for every scene that has an `image_prompt`; any
failure (refusal, rate limit, spent budget, bad reply) falls back to stock for that scene with a
warning, and a missing key or a missing slot falls back silently. A profile without the slot is
stock only, so existing `providers.toml` files keep loading. There is no separate `visuals`
setting.
**Cost:** no per-video choice between generated and stock (the UI has none to offer yet); a
video whose images keep failing quietly becomes a stock video, visible only in its warnings.

## D26. Spec 0.2: `scenes[].intent.image_prompt`, with a 0.1 migration
Generation needs a longer, richer sentence than a stock search phrase, and rule 4 keeps intent
apart from assets, so the prompt is a new optional intent field, not provenance only. A 0.1 spec
is valid as 0.2 once its version string changes; `Retake.Spec.migrate/1` does that on load. The
Rust renderer reads only 0.2.
**Cost:** a format bump across the schema, SPEC.md, examples, fixtures, Elixir and Rust; stored
jobs keep their 0.1 spec until something loads them.

## D27. Cloudflare Workers AI (FLUX.1 schnell) is the first image provider, with its own adapter
The only hosted free tier checked against primary docs (10,000 Neurons a day, no card). It speaks
its own API (token plus account id in the URL), so it gets a provider-specific adapter (D5); the
account id is read from an environment variable named in the config. Gemini's image models have
no free tier on Google's pricing page.
**Cost:** the free allowance and the model list are Cloudflare's to change; the documented
request has no width or height, so images may be square and `cover` fit crops their sides (the
step warns); one more account and two environment variables for the user.
```

- [ ] **Step 2: Append the F16 entry to `PROGRESS.md`** (fill in the measured facts from the user's Task 4 probe and the final real run; do not write numbers the user did not report):

```markdown

## F16. Generated images (passing, <date the user confirms>)

- 16a `image` capability (optional in a profile), `cloudflare_workers_ai_image` adapter, `mix retake.image` / `just image`, `cloudflare-flux` in the example config. Real probe by the user: <image size, call time, cache hit on the repeat>.
- 16b spec 0.2 (`intent.image_prompt`), `Retake.Spec.migrate/1` (0.1 to 0.2), Rust reads 0.2.
- 16c the script step writes `image_prompt` per scene (optional in the reply).
- 16d `Retake.Media.Image` (JPEG/PNG size), `Retake.Pipeline.Images`, `Retake.Pipeline.Visuals` (generated first, stock fallback with a warning).
- 16e the pipeline emits `:visual` events (were `:stock`); the web "Visuals" row reads `visual` and older `stock` entries.
- Verification: `just check`, `just test`, then `just image` and `just video` with the Cloudflare variables set. User reported: <result>.

Decisions: D25, D26, D27.

Left open:
- The prompt wording for `image_prompt` is a first draft.
- Scenes can look unlike each other (no shared style line yet).
- Cost and allowance: the free plan's real daily image count is unmeasured; `rate_limit = 150/day` is an estimate.
- The generated asset's licence says only "AI-generated: <model>"; check FLUX.1 schnell's terms before the UI shows it as a credit.
- <square-image decision from the Task 4 probe, if it applied>
```

- [ ] **Step 3: Update `features.json`.** Replace the F16 object with (state stays `"active"` until the user confirms the real run):

```json
    {
      "id": "F16-generated-images",
      "behavior": "Scenes can get a generated image instead of stock: the script step also writes an image_prompt per scene (spec 0.2, optional intent field); an optional image capability and the Cloudflare Workers AI adapter (FLUX.1 schnell) behind Retake.Providers.Client; a Visuals step makes a generated image when the profile has an image slot and the scene has a prompt, and falls back to stock on any failure (warning) or silently when no image provider or key is set; the image gets the renderer's zoom and pan; provenance source generated, with cost and the prompt; budget caps and rate limits apply.",
      "sub_steps": [
        "16a image capability (optional), Cloudflare adapter, mix retake.image / just image, example config; real probe of the output size",
        "16b spec 0.2 with intent.image_prompt and a 0.1 migration (Elixir, Rust, schema, SPEC.md, examples, fixtures)",
        "16c script step writes image_prompt",
        "16d Media.Image, Pipeline.Images, Pipeline.Visuals",
        "16e pipeline :visual events, Assemble, web Visuals row",
        "16f decisions D25-D27, PROGRESS, final verification and a real video"
      ],
      "verification": "cd api && mix test test/retake/providers test/retake/pipeline test/retake/media test/retake/spec_test.exs test/retake/videos && cd .. && cargo test -p retake_render && cd web && npm run typecheck && npm test   (then `just check` and `just test`; then the real run: `just image \"...\"` and `just video \"...\"` with CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID set)",
      "state": "active"
    },
```

- [ ] **Step 4: Full verification (User runs).**

```bash
unset MIX_ENV
just check 2>&1 | tail -15
just test > .retake/test-out.txt 2>&1; tail -25 .retake/test-out.txt
```
Expected: `just check` ends without errors (format, clippy, boundaries `boundaries ok`, web typecheck, fixtures); `just test` shows web `fail 0`, every Rust `test result: ok`, and Elixir `0 failures`. Paste the tails.

- [ ] **Step 5: The real run (User runs).**

```bash
source ~/.config/retake/env
just kokoro          # if it is not already running; wait for the 200 check printed by the recipe
just video "why we dream"
```
Expected: lines like `[scene 2] visual:  generated image for "..."` for scenes with an `image_prompt`, `[scene N] visual:  video for "..." (...)` for the others, a printed path of the MP4, and warnings (if any) at the end. Open the video and look at: do the generated scenes match their narration better than stock did; are any images cropped badly; do any scenes show the warning `not portrait`? Report what you see in plain words.

- [ ] **Step 6: Mark F16 passing only after the user says the real run worked.** In `features.json` set F16 `"state": "passing"`, and fill the two `<...>` placeholders in the `PROGRESS.md` entry with what the user reported (date, size, result). Say plainly what was and was not run.

- [ ] **Step 7: Hand over the final commit (User runs)**

```bash
git add DECISIONS.md PROGRESS.md features.json
git commit -m "docs: mark F16 passing, add D25-D27" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review (done against the spec)

**Spec coverage**
- 16a provider layer (`image` optional, adapter, normalised `steps`, example config, `mix retake.image`, `just image`): Tasks 2, 3, 4.
- 16b spec 0.2 (field, migration, Assemble, Rust, schema, SPEC.md, examples, fixtures): Task 5 (Assemble's `image_prompt` copy is in Task 9 with its test).
- 16c script step: Task 6.
- 16d `Media.Image`, `Images`, `Visuals`: Tasks 1, 7, 8.
- 16e pipeline event rename, Assemble key rename, web row, credits, progress docs: Tasks 9, 10. (`Videos.Progress` is generic over step names, so only its doc example mentions `stock`; left as an example, harmless.)
- 16f tests, decisions D25-D27, PROGRESS, features.json, real run: Task 11 and the tests inside each task.
- Risk (square images): measured in Task 4 Step 8, with a decision gate, warned in Task 7 and `mix retake.image`.
- Out of scope items (per-video UI choice, style line, seeds, spend display, F17, local model): not built.

**Placeholders:** the only `<...>` markers are the PROGRESS.md fields the user's real results fill in (Task 11 Steps 2 and 6); they are data, not missing design.

**Type consistency checked:** `Images.generate/2` returns `%{asset, prompt, warnings}`; `Visuals.find/3` returns `%{asset, query, source, prompt, warnings}`; `Pipeline` passes `%{visual: ..., voice: ...}` to `Assemble.build/1`, which reads `part.visual.asset`; event keys `kind, source, query, credit?, prompt?` match the web `StepEntry` and the `retake.video` printer; the error `{:capability_not_configured, :image}` is produced in `Providers.resolve/3` (Task 2), passed through `Client.call/4`, and matched in `Visuals` (Task 8) and `mix retake.image` (Task 4).

**Known soft spots to watch while executing**
- Task 3 Step 6: percent-encoding of `@` in the request path could change one assertion (handled by the note there).
- Task 9 Step 2: `defp` inside a `describe` block is legal Elixir; if the project's formatter or credo setup objects, hoist `sources/1`.
- Task 4 Step 8 depends on facts only the real call can settle (reply envelope, output size).
