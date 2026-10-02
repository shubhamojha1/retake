#!/usr/bin/env bash
# Self-test for check-boundaries.sh: clean tree passes, planted violations fail.
set -Eeuo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-boundaries.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/api/lib/retake/pipeline"
echo 'defmodule Retake.Pipeline.Script do end' > "$tmp/api/lib/retake/pipeline/script.ex"
echo 'defp deps, do: [{:phoenix, "~> 1.8"}]' > "$tmp/api/mix.exs"

bash "$check" "$tmp" >/dev/null || { echo "FAIL: clean tree rejected"; exit 1; }

echo 'def call, do: Req.get!("https://example.com")' >> "$tmp/api/lib/retake/pipeline/script.ex"
if bash "$check" "$tmp" >/dev/null 2>&1; then echo "FAIL: Req in pipeline accepted"; exit 1; fi

echo 'defmodule Retake.Pipeline.Script do end' > "$tmp/api/lib/retake/pipeline/script.ex"
echo 'alias Retake.Providers.Adapters.Groq' >> "$tmp/api/lib/retake/pipeline/script.ex"
if bash "$check" "$tmp" >/dev/null 2>&1; then echo "FAIL: adapter in pipeline accepted"; exit 1; fi

echo 'defmodule Retake.Pipeline.Script do end' > "$tmp/api/lib/retake/pipeline/script.ex"
echo 'defp deps, do: [{:vix, "~> 0.30"}]' > "$tmp/api/mix.exs"
if bash "$check" "$tmp" >/dev/null 2>&1; then echo "FAIL: media lib accepted"; exit 1; fi

echo "check-boundaries self-test ok"
