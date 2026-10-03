#!/usr/bin/env bash
# Checks a rendered MP4 against its spec: size, codec, pixel format, frame rate
# and frame count.
#
# Usage: scripts/probe-check.sh <spec.json> [video.mp4]
#        (default video: .retake/out/<spec id>.mp4, where `just render` writes it)
#
# Expected frame count: total scene time rounded to the nearest frame, half up
# (spec/SPEC.md, timing model). Cuts only until F04 adds overlapping transitions.
set -Eeuo pipefail

spec=${1:?usage: probe-check.sh <spec.json> [video.mp4]}
id=$(jq -r .id "$spec")
video=${2:-.retake/out/$id.mp4}
[ -f "$video" ] || {
  echo "FAIL: $video does not exist (run: just render $spec)" >&2
  exit 1
}

fps=$(jq -r .output.fps "$spec")
expected_frames=$(jq -r '([.scenes[].duration_ms] | add) as $ms | (($ms * .output.fps + 500) / 1000) | floor' "$spec")
probe=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,codec_name,pix_fmt,r_frame_rate,nb_frames -of json "$video")

status=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1 = $3"
  else
    echo "FAIL: $1: expected $2, got $3" >&2
    status=1
  fi
}
field() { jq -r ".streams[0].$1" <<<"$probe"; }

check width 1080 "$(field width)"
check height 1920 "$(field height)"
check codec h264 "$(field codec_name)"
check pix_fmt yuv420p "$(field pix_fmt)"
check r_frame_rate "$fps/1" "$(field r_frame_rate)"
check nb_frames "$expected_frames" "$(field nb_frames)"

[ "$status" -eq 0 ] && echo "$video ok"
exit "$status"
