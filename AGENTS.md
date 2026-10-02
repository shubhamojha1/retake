# Retake

Open-source, self-hostable AI video editor. Prompt → short vertical video using
any provider's API key; later, edits regenerate only what changed.
Product: `docs/PRODUCT.md`. Roadmap: `docs/ROADMAP.md` (only Phase 1 is active).
v1 plan: `docs/V1-PLAN.md`. Decisions: `DECISIONS.md`. Work queue:
`features.json`. Progress log: `PROGRESS.md`.

## Layout

- `api/`: Elixir/Phoenix 1.8 + Postgres. Pipeline, provider adapters, storage, cache, Channels. Port :4010.
- `crates/retake_render/`: Rust. Spec → MP4 renderer (library + CLI binary).
- `web/`: React + Vite + TypeScript + Tailwind. Minimal UI. Port :5173, proxies `/api` and `/socket` to :4010.
- `spec/`: the video format: schema, SPEC.md, examples.
- `config/`: `providers.example.toml` (copy to git-ignored `providers.toml`).
- `fixtures/`: small CC0 media and fixture specs for tests.
- `scripts/`: repo tooling (boundary check).

## Environment

Linux/WSL only. Toolchain is pinned by `flake.nix`/`flake.lock`: enter it with
`nix develop --impure` (or `direnv allow`). Nix only sees git-tracked files, so
`git add` new files before expecting the flake to see them. The repo lives on
the Linux filesystem (`~/projects/retake`), never `/mnt/c`.

## Commands

Run inside the Nix shell. `just --list` shows all.

- `just versions`: print pinned tool versions (shell health check).
- `just pg-start` / `pg-stop` / `pg-status`: local Postgres (data in `.pg/`).
- `just setup`: web deps, Rust crates, API deps + database (run once).
- `just dev`: Postgres + API (:4010) + web (:5173).
- `just test`: web, Rust and Elixir suites (also the boundary self-test).
- `just check`: web typecheck, `cargo fmt`/`clippy`, `mix format`, boundary check.
- `just render <spec.json>`: run the renderer on a spec.

## Hard rules

1. Work on one feature from `features.json` at a time. Mark it `passing` only
   after its verification command succeeds, and log it in `PROGRESS.md`.
2. The spec is the contract. Any format change updates the schema, SPEC.md,
   examples and `spec_version`, plus a migration for older versions.
3. Rendering must be deterministic: same spec + same asset bytes + same
   renderer version + same pinned FFmpeg → identical output (D12).
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
   not on concrete adapters. `just check-boundaries` enforces this.
10. Do not build features from later roadmap phases.
11. Record any non-obvious design choice in `DECISIONS.md` with its cost.
12. Never commit unless the user asks. The user runs build/test/dev commands
    in WSL; give exact commands and expected output instead of claiming a pass.
