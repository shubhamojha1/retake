# Retake

Open-source, self-hostable AI video editor. Prompt → short vertical video using
any provider's API key; later, edits regenerate only what changed.
Product: `docs/PRODUCT.md`. Roadmap: `docs/ROADMAP.md` (only Phase 1 is active).
Decisions: `DECISIONS.md`. Work queue: `features.json`. Progress log: `PROGRESS.md`.

## Layout (planned)

- `api/`: Elixir/Phoenix. Pipeline, provider adapters, storage, cache, Channels.
- `crates/retake_render/`: Rust. Spec → MP4 renderer (library + CLI binary).
- `web/`: React + Vite + TypeScript. Minimal UI.
- `spec/`: the video format: schema, SPEC.md, examples.
- `config/`: `providers.example.toml` (copy to git-ignored `providers.toml`).
- `fixtures/`: small CC0 media and fixture specs for tests.

## Commands

Filled in during setup. Expected: `just setup`, `just dev`, `just test`,
`just check`, `just render <spec.json>`.

## Hard rules

1. Work on one feature from `features.json` at a time. Mark it `passing` only
   after its verification command succeeds, and log it in `PROGRESS.md`.
2. The spec is the contract. Any format change updates the schema, SPEC.md,
   examples and `spec_version`, plus a migration for older versions.
3. Rendering must be deterministic: same spec + same asset bytes + same
   renderer version → identical output.
4. Scene `intent` and resolved assets stay separate. Never write assets
   without provenance (provider, model, request, request_hash, cost).
5. Every provider call goes through the provider layer and the request cache.
   No direct HTTP calls to providers from pipeline code.
6. Tests never touch the network. Use the `test` profile and recorded
   responses; an unrecorded call is a test failure.
7. API keys come only from environment variables. Never log, store or put
   keys in specs, provenance or fixtures.
8. The renderer runs as a separate process (Port). Elixir never links media
   libraries directly.
9. Pipeline code depends on behaviours (`Retake.Providers.*`, `Retake.Storage`),
   not on concrete adapters.
10. Do not build features from later roadmap phases.
11. Record any non-obvious design choice in `DECISIONS.md` with its cost.
