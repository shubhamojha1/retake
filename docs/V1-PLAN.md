# Retake v1 plan

v1 = Phase 1 in `context/docs/ROADMAP.md`. Prompt in, 30-60 s vertical MP4 out
(voice-over, captions, stock visuals, music), BYO provider keys, free profile.
Source material lives in `context/` (reference only). Our own versions of the
project files are written fresh in the repo root.

## Decisions made so far

Carried over unchanged from `context/DECISIONS.md`: D1-D8.

New (to be recorded as D9+ in `DECISIONS.md` during setup):

| # | Decision | Cost |
|---|---|---|
| D9 | Dev env = WSL2 Ubuntu + Nix flake (same shape as the Timbre scaffold). Repo lives in the WSL filesystem. CI uses the same flake. | Nix install in WSL; two filesystems on one machine. |
| D10 | Renderer = option B: FFmpeg decodes to raw frames, Rust composites (tiny-skia), raw frames piped to FFmpeg to encode. Compositor written so a GPU/WASM backend can follow in a later phase. | Real Rust work in F03/F04; piping raw frames costs throughput. |
| D11 | Postgres (per D2). Not SQLite as in the assignment. | Postgres in the flake and CI. |
| D12 | Byte-identical output (F06) is guaranteed only for the same pinned FFmpeg build, same machine class. FFmpeg pinned via Nix; encoder run single-threaded / bitexact. | Slower encode. |

## Differences from the assignment scaffold

Reuse: `flake.nix` shape (nixos-25.11, erlang 27, elixir 1.18, node 22,
rust-overlay), `justfile` style, `.envrc`, CI via `nix develop`, Phoenix 1.8 +
Bandit + Req + Jason, Vite + React 19 + Tailwind 4 + TS, node `--test` for web.

Change:
- Ecto Postgres instead of `ecto_sqlite3`.
- Drop wasm-pack, wasm32 target, `timbre_kit` (WASM preview is Phase 4).
- Add `crates/retake_render` (Cargo lib + bin), FFmpeg, Postgres to the flake.
- No prod Dockerfile in v1.

## Gaps in the original feature list

1. **No owner for jobs/videos in Postgres or the HTTP API** (`POST /api/videos`,
   `GET /api/videos/:id`, media file serving). Needed by F13 and F14. Cover in
   F13 (plan mode first) or add `F13a`.
2. **Two spec validators** (Elixir F01, Rust in F03). The JSON Schema is the
   shared source; add a cross-check test that both accept/reject the same
   example specs.
3. **External inputs**: CC0 media (F02), CC0 music library + manifest (F13),
   Kokoro server in Docker (free profile TTS), Groq and Pexels keys (F15 only).
4. **SPEC open questions**, each settled at the start of the feature that
   needs it: short clip (loop / freeze / reject) in F03; bundled fonts in F04;
   loudness pass location in F05.

## Order

Reordered 2026-10-04: the first goal is prompt-to-video end to end, even with
poor video quality. Polish comes after the pipeline and web MVP.

```
S0 setup ► F01 spec-validate ► F02 fixtures ► F03 render basic (silent, cuts)
   ► F05a voice-over audio ► F08 providers ► F09 storage+cache ► F07 renderer port
   ► F10 script ► F11 stock ► F12 voice+timing ► F13 e2e (+API/jobs)   <- prompt to video
   ► F14 web MVP
   ► then polish: F04 transitions+captions ► F05b music+loudness ► F06 determinism
   ► F15 acceptance
```

One feature at a time (hard rule 1). F03 and F13 get plan mode before code.
F05a adds only narration audio so the MVP videos speak; music, ducking and the
loudness pass wait for F05b.

**Needed before the first real end-to-end run (F13):** a Groq API key (LLM and
speech-to-text, free tier), a Pexels API key (stock footage, free), and a local
Kokoro text-to-speech server in Docker (`providers.example.toml`, `kokoro-local`).
Getting these in parallel saves time later.

## Definition of done (v1)

- 10 varied prompts each give a watchable video, no manual fixes, free profile.
- Same spec rendered twice gives byte-identical MP4 (D12 scope).
- Every provider call's cost and usage is in asset provenance.
- Whole suite passes under the `test` profile with no network.

## Next steps

1. S0 setup session: install Nix in WSL, move/clone repo into WSL, write
   AGENTS.md, DECISIONS.md (D1-D12), features.json, flake, justfile, CI,
   skeletons (`api/`, `crates/retake_render/`, `web/`), boundary check, PROGRESS.md.
2. Stop and review before any feature.
