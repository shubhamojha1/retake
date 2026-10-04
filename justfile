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
setup: pg-start
    cd web && npm ci
    cargo fetch --locked
    cd api && mix setup
    test -f config/providers.toml || { cp config/providers.example.toml config/providers.toml; echo "created config/providers.toml (git-ignored): export GROQ_API_KEY and PEXELS_API_KEY to use it"; }

# --- dev -------------------------------------------------------------------

# Run API (:4010) and web (:5173) together. Ctrl-C stops both.
dev: pg-start
    #!/usr/bin/env bash
    set -Eeuo pipefail
    (cd api && mix phx.server) &
    api_pid=$!
    trap 'kill $api_pid 2>/dev/null || true' EXIT
    cd web && npm run dev

# Phoenix API only, on http://localhost:4010 (IEx-attached).
api: pg-start
    cd api && iex -S mix phx.server

# Web dev server only, on http://localhost:5173 (proxies /api -> :4010).
web:
    cd web && npm run dev

# Write a video script for a topic with the real LLM: `just script "why tea is good for you"`.
# Needs config/providers.toml and GROQ_API_KEY (see `mix help retake.script` for options).
script *args:
    cd api && mix retake.script {{args}}

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
