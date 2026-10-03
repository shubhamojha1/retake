#!/usr/bin/env bash
# Verifies fixtures/specs against fixtures/media:
#   - every asset file exists
#   - content_hash matches the file bytes
#   - the spec's media info matches what ffprobe reports
#   - word timings fit the voice-over audio (gen-fixtures.sh uses a 500 ms grid per word)
# Does not regenerate anything. To refresh: scripts/gen-fixtures.sh.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/fixtures-lib.sh
source scripts/fixtures-lib.sh

status=0
bad() {
  echo "FAIL: $*" >&2
  status=1
}

specs=(fixtures/specs/*.json)
[ -e "${specs[0]}" ] || {
  echo "FAIL: no fixture specs in fixtures/specs" >&2
  exit 1
}

for spec in "${specs[@]}"; do
  while IFS=$'\t' read -r id kind uri hash media; do
    file=${uri#file://}
    if [ ! -f "$file" ]; then
      bad "$spec: asset $id: missing file $file"
      continue
    fi

    actual_hash=$(file_hash "$file")
    [ "$actual_hash" = "$hash" ] || bad "$spec: asset $id: content_hash is $hash, file has $actual_hash"

    actual_media=$(probe_media "$kind" "$file")
    jq -e -n --argjson a "$media" --argjson b "$actual_media" '$a == $b' >/dev/null ||
      bad "$spec: asset $id: media is $media, file has $actual_media"

    echo "ok   $spec  $id"
  done < <(jq -r '.assets | to_entries[] | [.key, .value.kind, .value.uri, .value.content_hash, (.value.media | tojson)] | @tsv' "$spec")

  while IFS=$'\t' read -r scene words audio_ms; do
    [ $((words * 500)) -eq "$audio_ms" ] ||
      bad "$spec: scene $scene: $words words need $((words * 500)) ms of audio, voice-over file is $audio_ms ms"
  done < <(jq -r '. as $s | .scenes[] | select(.voiceover) | [.id, (.voiceover.words | length), $s.assets[.voiceover.asset].media.duration_ms] | @tsv' "$spec")
done

[ "$status" -eq 0 ] && echo "fixtures ok"
exit "$status"
