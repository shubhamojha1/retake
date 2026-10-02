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
