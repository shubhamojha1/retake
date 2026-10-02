# Progress

Newest at the bottom. One entry per finished step or feature: what changed,
the verification command, its result, and anything left open.

## F00. Setup (passing, 2026-10-03)

User reported "all fine" after running the setup commands in WSL (`just setup`,
`just check`, `just test`) and confirmed that basic setup is complete before
requesting the F00 commit. Verification is user-reported; output was not captured
here and the agent did not rerun build/test commands.

Checklist:

- [x] Nix flake, `.envrc`, `.gitignore`, `.gitattributes`, `justfile` (env + Postgres recipes)
- [x] Project docs: AGENTS.md, CLAUDE.md, DECISIONS.md (D1-D12), features.json, spec/, config/
- [x] `api/` Phoenix + Postgres skeleton, health endpoint test
- [x] `crates/retake_render/` lib + bin skeleton, one test
- [x] `web/` Vite + React + TS skeleton, one test
- [x] `just setup / dev / test / check / render`
- [x] `just check-boundaries` + self-test (rules 5, 8, 9)
- [x] CI: check + test (written; first run on GitHub pending)
- [x] User confirmed setup verification in WSL; F00 commit requested
