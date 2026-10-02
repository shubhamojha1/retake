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

# Render a spec to MP4 with the Rust renderer: `just render fixtures/specs/minimal.json`.
render spec:
    cargo run -q -p retake_render -- {{spec}}

# --- build -----------------------------------------------------------------

# Production build of everything.
build:
    cd web && npm run build
    cargo build --release -p retake_render
    cd api && MIX_ENV=prod mix compile

# --- quality ---------------------------------------------------------------

# Run the web, Rust, and Elixir test suites, plus the boundary check self-test.
# Force MIX_ENV=test: the nix shell exports MIX_ENV=dev, which would otherwise
# override `mix test`'s implicit test env.
test: pg-start test-boundaries
    cd web && npm test
    cargo test --workspace
    cd api && MIX_ENV=test mix test

# Type-check the web app, lint Rust, format-check the API, enforce boundaries.
check: check-boundaries
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
