# shellcheck shell=bash
# Shared helpers for gen-fixtures.sh and verify-fixtures.sh. Source, don't run.
# Needs: ffprobe, jq, sha256sum.

# Prints "sha256:<hex>" for a file, the format of spec asset content_hash.
file_hash() {
  printf 'sha256:%s' "$(sha256sum "$1" | cut -d' ' -f1)"
}

# Prints the spec `media` object (compact JSON) for a file: probe_media <kind> <file>.
probe_media() {
  local kind=$1 file=$2 mime
  case "${file##*.}" in
    jpg) mime=image/jpeg ;;
    mp4) mime=video/mp4 ;;
    wav) mime=audio/wav ;;
    mp3) mime=audio/mpeg ;;
    *) echo "probe_media: unknown extension: $file" >&2; return 1 ;;
  esac

  case "$kind" in
    image)
      ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of json "$file" |
        jq -c --arg mime "$mime" '.streams[0] | {width, height, mime: $mime}'
      ;;
    video)
      ffprobe -v error -select_streams v:0 -show_entries stream=width,height:format=duration -of json "$file" |
        jq -c --arg mime "$mime" '{
          width: .streams[0].width,
          height: .streams[0].height,
          duration_ms: (.format.duration | tonumber * 1000 | round),
          mime: $mime
        }'
      ;;
    audio)
      ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels:format=duration -of json "$file" |
        jq -c --arg mime "$mime" '{
          duration_ms: (.format.duration | tonumber * 1000 | round),
          sample_rate: (.streams[0].sample_rate | tonumber),
          channels: .streams[0].channels,
          mime: $mime
        }'
      ;;
    *) echo "probe_media: unknown kind: $kind" >&2; return 1 ;;
  esac
}
