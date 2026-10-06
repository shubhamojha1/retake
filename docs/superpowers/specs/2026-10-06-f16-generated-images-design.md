# F16: generated images (design)

Date: 2026-10-06. Status: design approved in chat, written spec awaiting review.
Feature: `F16-generated-images` in `features.json`. Rules that apply: AGENTS 2, 4, 5, 6, 7, 9.

## Goal

A scene can show an AI-generated image instead of stock footage, so visuals match
the narration (the gap seen in the first real video: stock "only loosely matches").
Stock stays the default and the fallback. A video must never fail because an image
could not be made.

## Decisions taken (user, 2026-10-06)

- Provider kind: hosted free tier, not the local 8 GB GPU (the `vllm` container holds most of the VRAM).
- First service: Cloudflare Workers AI, model `@cf/black-forest-labs/flux-1-schnell`.
- The generation prompt is a new intent field, so the spec goes to 0.2 (AGENTS rule 2).

## Facts and what is still unverified

Verified in Cloudflare's docs (2026-10-06):
- Free allowance: 10,000 Neurons a day on the Free and Paid plans.
- FLUX.1 schnell price: 4.80 Neurons per 512x512 tile and 9.60 per step.
- Request: `POST https://api.cloudflare.com/client/v4/accounts/<id>/ai/run/@cf/black-forest-labs/flux-1-schnell`,
  `Authorization: Bearer <token>`, JSON `{prompt (1-2048 chars), steps (max 8, default 4), seed}`.
  Reply: JSON with `image`, a base64 JPEG.
- The docs list no width or height field.

Not verified, to be measured by `just image` (16a):
- The output size. Probably 1024x1024. My arithmetic (1024x1024 = 4 tiles, 4 steps: about 58 Neurons)
  gives about 170 images a day, but that assumes the size and the pricing reading.
- Latency, refusal behaviour (content filter) and what the API returns when the daily allowance is spent.

Gemini image models are not an option: Google's pricing page lists no free tier for them.

## Risk: square images

If the image is square, `fit: cover` on a 1080x1920 frame shows about 56% of its width.
16a measures the size first. If it is square, decide then between: prompting for a centred subject
(cheap), a Cloudflare model that accepts a portrait size (to be checked), or a blurred-background fit in
the renderer (renderer work, not in F16 unless chosen).

## Design

### 16a. Provider layer and a real probe

- `image` joins the capability lists in `Retake.Providers` and `Retake.Providers.Config`
  (`Cache.Entry` already knows `image`). It is **optional** in a profile: a `providers.toml`
  without it still loads. A profile with an `image` slot means "generated first, stock as
  fallback"; without it, stock only. There is no separate `visuals` setting.
- New adapter `Retake.Providers.Adapters.CloudflareWorkersAIImage`, registered as
  `"cloudflare_workers_ai_image"` (provider-specific API, so its own adapter, D5). On Req.
  - Settings in `providers.toml`: `model`, `account_id_env` (default `CLOUDFLARE_ACCOUNT_ID`), `steps` (default 4).
  - Token from `api_key_env = "CLOUDFLARE_API_TOKEN"`; the account id is read from the env var at
    call time. Neither is logged or stored (rule 7); the token is redacted from echoed errors like the other adapters.
  - `normalize_request/2` fills `steps` and the model into the request, so they are part of the cache key and provenance.
    No `seed` is sent: the cache already makes a repeat request return the same image (D6).
  - Reply: decode base64, return `{:binary, jpeg, "jpg"}`; usage `%{cost_usd: 0, units: %{steps: n}}`.
  - Errors map like the other adapters (rate limit, auth, refusal, bad reply); a reply that is not valid
    base64 or not a JPEG is an error and is never cached.
- `config/providers.example.toml`: provider `cloudflare-flux` (`capability = "image"`,
  `rate_limit = { requests_per_day = 150 }`), and `image = { use = "cloudflare-flux" }` in the `free` profile.
  With no Cloudflare variables set, `Providers.run` skips it (F08 behaviour), so `free` still works.
- `mix retake.image "<prompt>"` and `just image`: one real call through `Client`, stores the file and prints its
  path, size and whether it came from the cache. Modelled on `mix retake.stock`.

### 16b. Spec 0.2

- `scenes[].intent.image_prompt`: optional string, maxLength 600. `visual_query` stays the stock search phrase;
  its schema description is updated.
- `spec_version` becomes "0.2". `Retake.Spec` gets a migration 0.1 to 0.2 (changes only the version string),
  applied by `load/1` and `validate/1`, so older specs and stored jobs still work.
- `Assemble` writes 0.2 and copies `image_prompt` into the intent. The Rust `SUPPORTED_VERSION` becomes "0.2"
  and its intent struct accepts `image_prompt` (Elixir migrates before rendering, so Rust needs no 0.1 path).
- Update: `spec/video.schema.json`, `spec/SPEC.md`, `spec/examples/*`, `fixtures/specs/*`, and the
  scripts that read `spec_version`.

### 16c. Script step

- The LLM reply gains `image_prompt` per scene: English, one or two sentences, vertical composition, subject centred,
  concrete, no text, logos or real people's names.
- It is optional in the reply schema. A missing or blank prompt means that scene uses stock. Reason: a rejected script
  costs a retry or the whole run; a missing nice-to-have costs one scene its upgrade.
- `mix retake.script` prints it. The prompt wording is a first draft, like the rest (PROGRESS F10).

### 16d. Images and the Visuals step

- `Retake.Media.Image.dimensions/1`: width and height from JPEG (SOF markers) and PNG (IHDR) bytes, pure Elixir
  (the spec requires `media.width/height` on images; rule 8 keeps media libraries out of Elixir).
- `Retake.Pipeline.Images.generate(client, scene, opts)`: one `Client.call(client, :image, request)`; the stored result
  becomes a spec asset: `kind "image"`, `uri`, `content_hash`, `media` (width, height, mime), `provenance`
  (`Entry.provenance/1`: source `generated`, provider, model, request incl. the prompt, request_hash, cost), and
  `license` `{name: "AI-generated (FLUX.1 [schnell] via Cloudflare Workers AI)"}`. Warning if the image is not portrait.
- `Retake.Pipeline.Visuals.find(client, scene, opts)`:
  1. if the profile has an `image` provider and the scene has an `image_prompt`: `Images.generate`;
  2. on any error (refusal, rate limit, budget, missing key, bad reply), or when step 1 does not apply:
     `Stock.find`, adding a warning in the first case ("scene n: image failed (reason); used stock");
  3. returns `%{asset, query, source: :generated | :stock, warnings}`.
  Pipeline code calls providers only through `Client` (rules 5 and 9); `Visuals` never names an adapter.

### 16e. Pipeline and web

- `Retake.Pipeline` runs `Visuals.find` where it ran `Stock.find`. Event step `:stock` becomes `:visual`; its `:done`
  detail gains `source` and, for generated images, `prompt`. Credit is absent for generated images.
- `Assemble` input key `stock:` becomes `visual:`. A generated image is a still, so it already gets the slow zoom or pan.
- Web: `steps.ts` reads `visual` (and old `stock` entries) for the "Visuals" row; `scenes.ts` and `types.ts` follow; the credits
  list skips assets with no attribution. `Videos.Progress` doc and `mix retake.video` output follow.

### 16f. Verification, decisions, log

- Tests (none touch the network, rule 6): adapter with `Req.Test` stubs (ok, 429, refusal, bad base64, not a JPEG, no key,
  no account id); `Media.Image` with small real JPEG and PNG bytes; `Images` and `Visuals` with the scripted adapter
  (generated, fallback with warning, no image slot, no `image_prompt`); config accepts and omits `image`; spec migration;
  `Script` with and without `image_prompt`; the offline pipeline end to end; the Rust version check; web node tests.
- Proposed `features.json` verification (to finalise before starting, per its own rule):
  `cd api && mix test test/retake/providers test/retake/pipeline test/retake/media test/retake/spec_test.exs && cd .. && cargo test -p retake_render && cd web && npm run typecheck && npm test`,
  then the real run by the user: `just image` and `just video` with the Cloudflare variables set.
- `DECISIONS.md`: D25 optional `image` slot with stock fallback (cost: no per-video choice, and a failed image costs a
  warning, not an error); D26 spec 0.2 with `image_prompt` (cost: a version bump and migration across Elixir, Rust and fixtures);
  D27 Cloudflare adapter, account id from env, square-image risk.
- `PROGRESS.md` entry and `features.json` sub_steps added when work starts.

## Out of scope (not F16)

Per-video visuals choice in the UI; a shared style line so scenes look alike; seeds and "regenerate this scene" (Phase 2);
spend display; generated video (F17); a local image model.

## Self-review

- No placeholders. The licence wording for generated assets is a plain "AI-generated" name; checking the FLUX.1 schnell
  terms before the UI shows it as a credit is part of 16d.
- Consistent: the only spec change is the optional `image_prompt` field (16b), used by 16c and 16d.
- Scope: one feature, six sub-steps, each testable alone; 16a can ship and be probed before the rest.
- Ambiguity fixed: "generated first" is decided by the presence of the `image` slot and of the scene's `image_prompt`, nothing else.
