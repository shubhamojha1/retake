# Starting Retake with Claude Code

This file is for you, not for the agent. Delete it once setup is done.

## 1. Put the context pack in the new repo

```
retake/
├── AGENTS.md                      agent instructions (rules, layout)
├── CLAUDE.md                      one line: @AGENTS.md
├── DECISIONS.md                   D1–D8, the decisions already made
├── features.json                  Phase 1 work queue, F01–F15
├── docs/PRODUCT.md                what Retake is and isn't
├── docs/ROADMAP.md                phases; only Phase 1 active
├── spec/SPEC.md                   the video format, explained
├── spec/video.schema.json         the video format, machine-checkable
├── spec/examples/*.json           example specs
└── config/providers.example.toml  providers and profiles
```

Commit this as the first commit ("docs: project context").

## 2. Make your harness-init skill available

Copy `my-skills/skills/harness-init/` to `~/.claude/skills/harness-init/` (all
projects) or `retake/.claude/skills/harness-init/` (this repo only).

## 3. Session 1: setup only, no features

Paste:

> Read AGENTS.md, DECISIONS.md, docs/PRODUCT.md, docs/ROADMAP.md, spec/SPEC.md
> and features.json first. Then run the harness-init skill for this repo.
>
> Keep the existing AGENTS.md, DECISIONS.md and features.json: extend them,
> don't replace them. Add new setup decisions to DECISIONS.md as D9 onward.
>
> Set up:
> - Pinned toolchain (Nix flake like my Timbre repo, or mise if simpler):
>   Elixir/OTP, Rust stable, Node LTS, FFmpeg, Postgres.
> - Skeletons: `api/` (Phoenix, Postgres), `crates/retake_render/` (lib + bin),
>   `web/` (Vite + React + TS). Each with one trivial passing test.
> - A `justfile` with setup, dev, test, check, render.
> - CI running check + test.
> - An executable boundary check: pipeline modules may not call adapter
>   modules or HTTP clients directly (rule 5 and 9 in AGENTS.md).
> - PROGRESS.md.
>
> Do not implement any feature from features.json. Stop when setup is done,
> show me the checklist, and wait for my review.

Then review every file it made, run `just test` yourself, and commit.

## 4. One session per feature

Start each feature in a fresh session (`/clear`). Paste, changing the id:

> Next feature: F01-spec-validate from features.json.
> Read the relevant docs first (AGENTS.md, spec/SPEC.md for this one).
> 1. Restate the behaviour and the verification command. Propose changes to
>    the command if it's weak, and wait for my OK.
> 2. Write the tests first, run them, show they fail.
> 3. Implement until the verification command passes.
> 4. Set the feature to passing, add a PROGRESS.md entry, and any decision to
>    DECISIONS.md.
> Don't touch other features.

For the big ones (F03 renderer, F13 pipeline), use plan mode first
(shift+tab) and agree the design before any code.

## 5. Decide this before F03 (the renderer)

How the Rust renderer produces video. Options:

| Option | How | Trade-off |
|---|---|---|
| A. FFmpeg CLI only | Rust turns the spec into one big FFmpeg filtergraph | Fastest to working; Rust becomes a thin wrapper, hard to debug, weak for live preview later |
| B. Rust composites, FFmpeg encodes | FFmpeg decodes inputs to raw frames; Rust draws each output frame (scaling, motion, text, fades) with a 2D library (e.g. tiny-skia); raw frames piped to FFmpeg to encode | Real Rust work, deterministic, same compositor can go to WASM for preview in Phase 4 |
| C. Rust + GPU (wgpu) | Like B, compositing on the GPU | Fastest renders, most to learn; overkill for Phase 1 |

My suggestion: **B**, with the compositor written so it can later run on the
GPU. Record the choice as a decision.

## 6. Habits that keep the agent on track

- One feature per session. `/clear` between features.
- Never let it mark a feature passing without running the command in front of you.
- Read every diff before committing. Run `/code-review` on bigger ones.
- If it starts building a later phase's feature, stop it and point at rule 10.
- When something surprises you, add a rule to AGENTS.md (keep it under 15).
- Copy Timbre files in only when a feature needs them (the provider pattern
  for F08, the WAV encoder/DSP if the renderer needs them), with their tests.
