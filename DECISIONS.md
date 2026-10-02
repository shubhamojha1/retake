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
