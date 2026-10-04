# Decisions

Newest at the bottom. Each entry: what, why, what it costs us.

## D1. Start a fresh repo instead of extending Timbre
Retake's core is a timeline spec, assets and render jobs; Timbre's is recordings
in SQLite. Specific Timbre pieces (provider behaviour, DSP, WAV encoder,
recorder, session mixer) are copied in when a phase needs them.
**Cost:** some re-setup work (Nix, CI, project skeleton).

## D2. Stack: Elixir/Phoenix + Rust + React, Postgres
Elixir orchestrates slow, failing, paid provider calls and pushes progress live.
Rust does rendering and media work. Postgres instead of SQLite because render
workers and the API will be separate processes later.
**Cost:** two toolchains plus a database to run locally.

## D3. Spec first
The video is a JSON document (`spec/video.schema.json`). The pipeline writes
it, the renderer reads it, the edit agent (Phase 3) changes it. Intent is
stored separately from resolved assets so edits can invalidate precisely.
**Cost:** format changes need version bumps and migrations.

## D4. Renderer is a Rust binary called from Elixir as a Port
Spec in, MP4 out, progress lines on stdout. Crashes in the renderer can't take
down the BEAM, and it can later run on separate machines unchanged.
**Cost:** process startup per render; streaming progress needs a small line protocol.

## D5. Providers by capability, bring your own key
Capabilities (llm, tts, stt, stock, music) map to providers through
`config/providers.toml`, with profiles (`free`, `dev`, `test`). One
OpenAI-compatible adapter covers most LLM/TTS/STT services. Keys come only
from environment variables.
**Cost:** lowest-common-denominator API surface; provider-specific features need their own adapter.

## D6. Every generated asset is cached by request hash
`request_hash = sha256(provider, model, normalised request)`. Same request,
same asset, no provider call. Protects free-tier quotas from day one and is the
base for Phase 2's scoped regeneration.
**Cost:** cache invalidation rules must be explicit; non-deterministic providers return the cached result, not a fresh one, unless forced.

## D7. Storage behind a behaviour
`Retake.Storage` with a local-disk implementation now, S3-compatible later.
**Cost:** none meaningful.

## D8. Tests never touch the network
The `test` profile replays recorded provider responses and fails on any
unrecorded call.
**Cost:** recordings must be refreshed when adapters change.

## D9. Dev environment: WSL2 Ubuntu + Nix flake
The toolchain (Elixir 1.18/OTP 27, Node 22, Rust stable, FFmpeg, Postgres 17,
just) is pinned in `flake.nix` + `flake.lock`, same shape as the Timbre
scaffold; CI uses the same flake. The repo lives on the WSL Linux filesystem.
All commands are Linux/bash; the justfile uses bash.
**Cost:** Nix install in WSL; native Windows is unsupported; large first download.

## D10. Renderer: Rust composites, FFmpeg decodes and encodes
FFmpeg decodes inputs to raw frames; Rust draws each output frame (scale,
motion, text, fades) with a 2D library (tiny-skia); raw frames are piped to
FFmpeg to encode. The compositor is written behind a small interface so a GPU
(wgpu) or WASM backend can follow in a later phase.
**Cost:** real Rust work in F03/F04; piping raw 1080x1920 frames costs throughput.

## D11. Postgres, not SQLite
Follows D2. Unlike the Timbre assignment, which used SQLite. Local dev uses a
Postgres cluster in `.pg/` (`just pg-start`), CI uses the Nix-provided one.
**Cost:** a running database for dev and tests.

## D12. Determinism scope
Byte-identical output (rule 3, F06) is guaranteed only for the same renderer
version and the same pinned FFmpeg build (via `flake.lock`) on the same CPU
architecture. FFmpeg is run single-threaded with bitexact flags.
**Cost:** slower encode; output may differ across FFmpeg versions or architectures.

## D13. A video clip shorter than its scene freezes on its last frame
The renderer holds the final decoded frame until the scene ends. Chosen over
looping (can show a visible jump, more code) and rejecting (real stock clips are
often shorter than the narration). Documented in `spec/SPEC.md`.
**Cost:** a long freeze looks like a pause. The stock step (F11) should prefer
clips at least as long as the scene.

## D14. The renderer warns and skips spec features whose feature is not built yet
Until each lands, the renderer prints `warning:` lines on stderr and renders
without: voice-over and music audio (F05), captions, overlays and non-cut
transitions (F04). A crossfade becomes a cut. Each warning goes away with the
feature that implements it.
**Cost:** a render can silently differ from the spec's intent. Elixir (F07) must
surface the warnings, and the checks in each feature's tests must fail if a
warning remains.

## D15. Validation is split: Elixir is the gate, Rust parses strictly
`Retake.Spec` (F01) enforces ranges, patterns and semantic rules. The renderer
parses the spec into strict typed structs (unknown fields and wrong types are
rejected, enums are checked) plus sanity checks (spec_version, 1080x1920, fps),
and fails clearly on anything it cannot proceed without (missing asset file).
No JSON Schema crate in Rust.
**Cost:** two parsers for one format; numeric ranges are unchecked in Rust, so a
spec can pass Rust and fail F01. A cross-check test uses the shared examples.

## D16. Provider usage counters live in memory, behind one module
Rate-limit windows (minute, hour, day, month) and budget spend are kept by
`Retake.Providers.Usage`, a GenServer. Reservations are atomic: the check and the
count happen in one call, so parallel scenes cannot both slip under a limit. The
day budget and the day/month rate windows are rolling (24 h, 30 days), not calendar.
**Cost:** counters reset when the app restarts, so a restart forgets today's usage.
A `provider_calls` table (also the audit log the Phase 1 criteria want) replaces
the module's internals later; callers do not change.

## D17. `toml_elixir` parses `config/providers.toml`
Elixir has no built-in TOML parser. `toml_elixir` is maintained (TOML 1.0) but
less widely used than `toml`, which has not been updated since 2022.
**Cost:** a small dependency on a less popular package; swap it if it goes stale.

## D18. `request_hash` is sha256 of Python-style canonical JSON of `[provider, model, request]`
Keys sorted, separators `", "` and `": "`, non-ASCII escaped as `\uXXXX`. This is
exactly how every `request_hash` in `spec/examples/explainer.json` was made, so
those examples are the golden tests and existing hashes stay valid.
**Cost:** floats must print the way Python prints them for typical values (`1.0`,
`0.5`); exotic floats (`1e-5`) may hash differently, so requests should avoid them.
A change to the scheme invalidates every cache entry.

## D19. The request cache is one JSON file per request hash
`<cache root>/<hex>.json` holds the provenance (provider, model, request,
request_hash, created_at, cost) and the result (a JSON value, or a pointer to a
stored asset). Plain files: inspectable and no migration. A missing asset or a
corrupt entry counts as a miss and is repaired. Failures are never cached.
**Cost:** no single-flight: two identical concurrent requests can both call the
provider. Postgres can replace the files when workers become separate processes.

## D20. Assets are stored as `store://assets/<sha256 hex>.<ext>`
Content-addressed, so the same bytes are stored once and the uri is its own
integrity check (`Storage.verify`). The extension is kept because some readers
(the renderer's image decoder) pick the format from it; it is validated
(`[a-z0-9]{1,8}`) and uris are parsed strictly, so no path can escape the root.
Writes go to a temp file and are renamed into place.
**Cost:** the same bytes with a different extension are two entries.

## D21. Pipeline steps call providers only through `Retake.Providers.Client`, and a reply is validated before it is cached
`Client.call/4` resolves the providers, looks in the request cache for each in turn,
calls them with fallbacks, rate limits and the budget, and stores the answer with its
provenance. Its `:validate` option runs on every fresh answer before storing: a reply
that fails counts as that provider failing and is never cached. Otherwise a malformed
LLM reply would be served from the cache on every retry. The script step retries a
rejected reply with the errors spelled out, up to 3 attempts; a retry is a different
request, so it has its own cache entry.
**Cost:** a brief whose first reply is always invalid pays for a failed call each run
(the good retry is cached under the retry's request, not the original); an invalid
answer is not charged to the budget even though it cost tokens.

## D22. Stock footage is two cached provider calls: search, then download
A stock search returns JSON candidates; the chosen candidate's file is a second call
that returns bytes into `Retake.Storage`. Both go through `Retake.Providers.Client`,
so both are cached and rate-limited, and pipeline code never makes an HTTP request.
The download request carries the query and rank, so the stored asset's provenance
says how it was found. The adapter only downloads from the stock service's own
hosts (https, an allowlist), because the URL comes from an API response.
**Cost:** a download counts against the provider's rate limit like a search does;
the same file found by two queries is downloaded twice (storage keeps one copy).

## D23. A video job is one database row, run by one background process, and is not resumed after a restart
`Retake.Videos.Runner` runs `Retake.Pipeline` under `Retake.TaskSupervisor`, and its events
come back to the runner process, which alone writes the row (progress as a JSON column, kept by
the pure `Retake.Videos.Progress`) and broadcasts on PubSub `video:<id>`. A crash in the pipeline
becomes a failed job. Every event is broadcast; the row is written on each event except render
progress, which is written every 5%. When the app starts, jobs left queued or running are marked
failed ("the app stopped"): the user asks again, and the request cache makes the repeat cheap.
`progress` leaves out server file paths: a finished video is reached by its `video_url`.
**Cost:** no job queue, no limit on jobs at once (each job already runs 3 scenes at a time, and the
providers' rate limits and budget are shared through `Retake.Providers.Usage`), and a restart loses
the render in progress.
