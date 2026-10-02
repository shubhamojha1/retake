#!/usr/bin/env bash
# Architecture boundary check (AGENTS.md rules 5, 8, 9).
#
#   Rule 5/9: pipeline code (api/lib/retake/pipeline*) must not touch HTTP
#             clients or concrete adapters (providers, storage backends).
#             It depends on the behaviours Retake.Providers.* / Retake.Storage.
#   Rule 8:   Elixir never links media libraries; media work is the renderer's.
#
# Usage: scripts/check-boundaries.sh [repo_root]
set -Eeuo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
status=0

# HTTP clients and concrete implementations banned from pipeline code.
pipeline_banned='\bReq\b|:httpc|HTTPoison|\bTesla\b|\bFinch\b|\bMint\b|Retake\.Providers\.Adapters|Retake\.Storage\.(Local|S3)'

pipeline_paths=()
[ -f "$root/api/lib/retake/pipeline.ex" ] && pipeline_paths+=("$root/api/lib/retake/pipeline.ex")
[ -d "$root/api/lib/retake/pipeline" ] && pipeline_paths+=("$root/api/lib/retake/pipeline")

if [ "${#pipeline_paths[@]}" -gt 0 ]; then
  if grep -rnE --include='*.ex' "$pipeline_banned" "${pipeline_paths[@]}"; then
    echo "boundary violation: pipeline code uses an adapter or HTTP client directly (rules 5, 9)" >&2
    status=1
  fi
fi

# Media libraries banned from the Elixir app (rule 8).
media_banned='\{:(evision|membrane[a-z_]*|xav|vix|image|nx_image|ffmpex|thumbnex)\b'
if [ -f "$root/api/mix.exs" ] && grep -nE "$media_banned" "$root/api/mix.exs"; then
  echo "boundary violation: api/mix.exs depends on a media library (rule 8)" >&2
  status=1
fi

[ "$status" -eq 0 ] && echo "boundaries ok"
exit "$status"
