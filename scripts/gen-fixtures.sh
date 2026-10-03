#!/usr/bin/env bash
# Generates fixtures/media with FFmpeg's built-in sources, then writes content
# hashes, media info and word timings into fixtures/specs/*.json.
#
# The media is committed to git: a different FFmpeg build may encode different
# bytes, which would break the hashes. Run this only to change the fixtures.
#
# Voice-overs are beeps, not speech: one 400 ms beep per word of the scene's
# narration, on a 500 ms grid. Word timings follow the same grid, so they match
# the audio exactly. The narration text in the spec is the single source.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/fixtures-lib.sh
source scripts/fixtures-lib.sh

media=fixtures/media
mkdir -p "$media"

# Same input, same bytes: no metadata, bit-exact muxing and encoding.
exact=(-fflags +bitexact -flags +bitexact -map_metadata -1)

# -nostdin: ffmpeg would otherwise swallow the stdin of the read loops below.
ff() {
  ffmpeg -nostdin -hide_banner -loglevel error -y "$@"
}

# image <name> <lavfi source>: one 1350x2400 (9:16) JPEG, 1.25x the output size so Ken Burns can pan.
image() {
  ff -f lavfi -i "$2" -frames:v 1 -update 1 -q:v 3 -pix_fmt yuvj420p "${exact[@]}" "$media/$1.jpg"
}

# vo <file> <n_words>: n 400 ms beeps on a 500 ms grid, 24 kHz mono WAV, n * 500 ms long.
vo() {
  local file=$1 n=$2 gate=0 k
  for ((k = 0; k < n; k++)); do
    gate+="+between(t,$(awk -v k="$k" 'BEGIN { printf "%.1f,%.1f", k * 0.5, k * 0.5 + 0.4 }'))"
  done
  local seconds
  seconds=$(awk -v n="$n" 'BEGIN { printf "%.1f", n * 0.5 }')
  ff -f lavfi -i "aevalsrc='0.4*sin(2*PI*220*t)*(${gate})':s=24000:d=${seconds}:c=mono" \
    -c:a pcm_s16le "${exact[@]}" "$file"
}

echo "images"
image sea "testsrc2=size=1350x2400:rate=1:duration=1"
image gradient "gradients=size=1350x2400:rate=1:duration=1:seed=7"
image bars "smptebars=size=1350x2400:rate=1:duration=1"
image wide "testsrc2=size=2400x1350:rate=1:duration=1"

echo "video clip"
ff -f lavfi -i "testsrc2=size=720x1280:rate=30:duration=6" \
  -c:v libx264 -preset medium -crf 28 -pix_fmt yuv420p -x264-params threads=1:bitexact=1 -an \
  "${exact[@]}" "$media/clip.mp4"

echo "music"
ff -f lavfi \
  -i "aevalsrc='0.15*(sin(2*PI*220*t)+sin(2*PI*277.18*t)+sin(2*PI*329.63*t))*(0.8+0.2*sin(2*PI*0.25*t))':s=44100:d=20:c=stereo" \
  -c:a libmp3lame -b:a 64k "${exact[@]}" "$media/music.mp3"

echo "voice-overs"
for spec in fixtures/specs/*.json; do
  while IFS=$'\t' read -r uri n; do
    vo "${uri#file://}" "$n"
  done < <(jq -r '. as $s | .scenes[] | select(.voiceover) | [$s.assets[.voiceover.asset].uri, (.intent.narration | split(" ") | length)] | @tsv' "$spec")
done

# Fill hashes and media info for every asset, and word timings for every voice-over.
fill_spec() {
  local spec=$1 tmp id kind uri file media
  tmp=$(mktemp)
  cp "$spec" "$tmp"

  while IFS=$'\t' read -r id kind uri; do
    file=${uri#file://}
    media=$(probe_media "$kind" "$file")
    jq --arg id "$id" --arg hash "$(file_hash "$file")" --argjson media "$media" \
      '.assets[$id].content_hash = $hash | .assets[$id].media = $media' "$tmp" >"$tmp.next"
    mv "$tmp.next" "$tmp"
  done < <(jq -r '.assets | to_entries[] | [.key, .value.kind, .value.uri] | @tsv' "$spec")

  jq '.scenes |= map(
        if .voiceover then
          .voiceover.words = (.intent.narration | split(" ") | to_entries
            | map({text: .value, start_ms: (.key * 500), end_ms: (.key * 500 + 400)}))
        else . end)' "$tmp" >"$spec"
  rm -f "$tmp"
}

echo "specs"
for spec in fixtures/specs/*.json; do
  fill_spec "$spec"
  echo "filled $spec"
done

echo "done. Now run: just verify-fixtures"
