# retake — Phoenix API + Rust renderer + React web.
# Run inside the Nix shell: `nix develop --impure` (or `direnv allow`).
# `just --list` shows everything.

set shell := ["bash", "-Eeuo", "pipefail", "-c"]

# Default recipe shows available commands
default:
    @just --list --unsorted

# --- environment -------------------------------------------------------------

# Print versions of every pinned tool. Quick check that the Nix shell is healthy.
versions:
    elixir --version | tail -1
    erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().'
    node --version
    cargo --version
    rustc --version
    ffmpeg -version | head -1
    postgres --version
    just --version
    jq --version

# --- local Postgres (data in .pg/, gitignored) ---------------------------------

# Create the local Postgres cluster. Safe to re-run.
pg-init:
    #!/usr/bin/env bash
    set -Eeuo pipefail
    if [ -d "$PGDATA" ]; then echo "pg-init: $PGDATA already exists"; exit 0; fi
    mkdir -p "$(dirname "$PGDATA")"
    initdb --username=postgres --auth=trust --encoding=UTF8 --locale=C.UTF-8 "$PGDATA"
    # TCP only, no unix socket (avoids socket path/permission issues on /mnt and in CI)
    {
      echo "listen_addresses = '127.0.0.1'"
      echo "port = $PGPORT"
      echo "unix_socket_directories = ''"
    } >> "$PGDATA/postgresql.conf"

# Start the local Postgres in the background. Safe to re-run.
pg-start: pg-init
    #!/usr/bin/env bash
    set -Eeuo pipefail
    if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then echo "pg-start: already running"; exit 0; fi
    pg_ctl -D "$PGDATA" -l "$PGDATA/../pg.log" -w start

# Stop the local Postgres.
pg-stop:
    pg_ctl -D "$PGDATA" -m fast stop

# Show whether the local Postgres is running.
pg-status:
    pg_ctl -D "$PGDATA" status

# --- setup -----------------------------------------------------------------

# One-shot: install web deps, fetch Rust crates, set up the API + database.
setup: pg-start hooks
    cd web && npm ci
    cargo fetch --locked
    cd api && mix setup
    test -f config/providers.toml || { cp config/providers.example.toml config/providers.toml; echo "created config/providers.toml (git-ignored): export GROQ_API_KEY and PEXELS_API_KEY to use it"; }

# Use the repo's git hooks (.githooks/pre-commit: format and boundary checks). Local to this clone.
hooks:
    chmod +x .githooks/pre-commit
    git config core.hooksPath .githooks

# --- dev -------------------------------------------------------------------

# Run API (:4010) and web (:5173) together. Ctrl-C stops both.
# Builds the release renderer (videos are rendered by it) and migrates the dev database first.
dev: pg-start build-renderer
    #!/usr/bin/env bash
    set -Eeuo pipefail
    (cd api && mix ecto.migrate && mix phx.server) &
    api_pid=$!
    trap 'kill $api_pid 2>/dev/null || true' EXIT
    cd web && npm run dev

# Phoenix API only, on http://localhost:4010 (IEx-attached). Same preparation as `just dev`.
api: pg-start build-renderer
    cd api && mix ecto.migrate
    cd api && iex -S mix phx.server

# Web dev server only, on http://localhost:5173 (proxies /api -> :4010).
web:
    cd web && npm run dev

# End-to-end check of the RUNNING system with real services: asks `just api` for a 5 second video,
# follows it over the websocket and fetches the MP4 by byte range. Minutes, network: not part of `just test`.
# Needs `just api`, `just kokoro` and the provider keys (see `mix help retake.video`).
e2e-smoke:
    cd web && node scripts/e2e-smoke.mjs

# Write a video script for a topic with the real LLM: `just script "why tea is good for you"`.
# Needs config/providers.toml and GROQ_API_KEY (see `mix help retake.script` for options).
script *args:
    cd api && mix retake.script {{args}}

# Make a whole video from a topic: `just video "why tea is good for you"`. Builds the renderer first.
# Needs Kokoro (`just kokoro`) and GROQ_API_KEY + PIXABAY_API_KEY (see `mix help retake.video`).
video *args: build-renderer
    cd api && mix retake.video {{args}}

# Build the release renderer that `just video` and `just dev` run.
build-renderer:
    cargo build --release -p retake_render

# Speak a narration, transcribe it and time its words: `just voice "Tea calms the mind."`.
# Needs the Kokoro server (`just kokoro`) and GROQ_API_KEY (see `mix help retake.voice`).
voice *args:
    cd api && mix retake.voice {{args}}

# Start the Kokoro text-to-speech server (CPU) on http://localhost:8880. First start downloads the image and model.
kokoro:
    #!/usr/bin/env bash
    set -Eeuo pipefail
    if docker ps --format '{{"{{.Names}}"}}' | grep -qx retake-kokoro; then echo "kokoro already running"; exit 0; fi
    docker rm -f retake-kokoro >/dev/null 2>&1 || true
    docker run -d --name retake-kokoro -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu:latest
    echo "kokoro starting: wait until  curl -s localhost:8880/docs -o /dev/null -w '%{http_code}'  prints 200"

# Stop and remove the Kokoro server.
kokoro-stop:
    docker rm -f retake-kokoro

# Find and download stock footage for a phrase: `just stock "steaming tea cup closeup"`.
# Needs PIXABAY_API_KEY or PEXELS_API_KEY (see `mix help retake.stock`).
stock *args:
    cd api && mix retake.stock {{args}}

# Render a spec to .retake/out/<id>.mp4 (release build: debug is far too slow for video).
render spec:
    cargo run -q --release -p retake_render -- {{spec}}

# Check a rendered MP4 against its spec (size, codec, frame rate, frame count).
probe-check spec:
    bash scripts/probe-check.sh {{spec}}

# --- build -----------------------------------------------------------------

# Production build of everything.
build:
    cd web && npm run build
    cargo build --release -p retake_render
    cd api && MIX_ENV=prod mix compile

# --- quality ---------------------------------------------------------------

# Run the web, Rust, and Elixir test suites, plus the boundary check self-test.
# MIX_ENV=test is explicit so a MIX_ENV exported in your own shell can't leak in.
test: pg-start test-boundaries
    cd web && npm test
    cargo test --workspace
    cargo build -p retake_render
    cd api && MIX_ENV=test mix test

# Type-check the web app, lint Rust, format-check the API, enforce boundaries, verify fixture files.
check: check-boundaries
    bash scripts/verify-fixtures.sh
    cd web && npm run typecheck
    cargo fmt --all --check
    cargo clippy --workspace --all-targets -- -D warnings
    cd api && mix format --check-formatted

# Pipeline code must not use adapters or HTTP clients directly (AGENTS.md rules 5, 8, 9).
check-boundaries:
    bash scripts/check-boundaries.sh

# Self-test: the boundary check must fail on a planted violation.
test-boundaries:
    bash scripts/test-check-boundaries.sh

# --- fixtures ----------------------------------------------------------------

# Check fixture hashes, media info and word timings, then load every fixture spec through Retake.Spec.
verify-fixtures: pg-start
    bash scripts/verify-fixtures.sh
    cd api && MIX_ENV=test mix test test/retake/fixtures_test.exs

# Regenerate fixtures/media with FFmpeg and refresh the specs. Rarely needed: the media is committed.
gen-fixtures:
    bash scripts/gen-fixtures.sh
