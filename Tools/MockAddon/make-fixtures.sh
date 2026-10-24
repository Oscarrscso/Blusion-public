#!/usr/bin/env bash
# Generates offline test media for the mock addon. Nothing here needs the internet.
# Output: Tools/MockAddon/fixtures/generated/ (git-ignored, never committed)
#   sample.mp4        10 s H.264 + AAC, faststart
#   hls/index.m3u8    same clip, 2 s segments (VOD)
#   sample-ac3.mkv    H.264 + AC3
#   sample-dts.mkv    H.264 + DTS (only if ffmpeg's experimental `dca` encoder exists)
#   sample.srt/.vtt   subtitles with known cue times (see subtitles.js)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/fixtures/generated}"
DUR=10

command -v ffmpeg >/dev/null 2>&1 || { echo "make-fixtures: ffmpeg not found (brew install ffmpeg / apt install ffmpeg)" >&2; exit 2; }

# Re-use existing output when it is complete and newer than this script.
if [[ -f "$OUT/sample.mp4" && -f "$OUT/hls/index.m3u8" && -f "$OUT/sample-ac3.mkv" && -f "$OUT/sample.srt" \
      && "$OUT/sample.mp4" -nt "${BASH_SOURCE[0]}" && -z "${FORCE:-}" ]]; then
  echo "make-fixtures: up to date ($OUT)"
  exit 0
fi

mkdir -p "$OUT/hls"
rm -f "$OUT"/hls/*

FF=(ffmpeg -hide_banner -loglevel error -y)
VIDEO=(-f lavfi -i "testsrc=duration=$DUR:size=640x360:rate=25")
# Silent audio: the same mono 44.1 kHz track a tone would give, so the clips test the same things without sounding through the Mac's
# speakers when the player tests play them.
AUDIO=(-f lavfi -t "$DUR" -i "anullsrc=channel_layout=mono:sample_rate=44100")
V264=(-c:v libx264 -preset veryfast -pix_fmt yuv420p -profile:v main -g 50 -keyint_min 50 -sc_threshold 0)

echo "make-fixtures: mp4 (H.264/AAC)"
"${FF[@]}" "${VIDEO[@]}" "${AUDIO[@]}" "${V264[@]}" -c:a aac -b:a 96k -shortest -movflags +faststart "$OUT/sample.mp4"

echo "make-fixtures: hls (2 s segments)"
"${FF[@]}" "${VIDEO[@]}" "${AUDIO[@]}" "${V264[@]}" -c:a aac -b:a 96k -shortest \
  -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_filename "$OUT/hls/seg%03d.ts" "$OUT/hls/index.m3u8"

echo "make-fixtures: mkv (H.264/AC3)"
"${FF[@]}" "${VIDEO[@]}" "${AUDIO[@]}" "${V264[@]}" -c:a ac3 -b:a 192k -shortest "$OUT/sample-ac3.mkv"

ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"   # not piped into grep -q: SIGPIPE + pipefail would misreport
if grep -qE ' dca ' <<<"$ENCODERS"; then
  echo "make-fixtures: mkv (H.264/DTS)"
  "${FF[@]}" "${VIDEO[@]}" "${AUDIO[@]}" "${V264[@]}" -c:a dca -strict -2 -b:a 768k -shortest "$OUT/sample-dts.mkv" \
    || { echo "make-fixtures: DTS encode failed, skipping sample-dts.mkv" >&2; rm -f "$OUT/sample-dts.mkv"; }
else
  echo "make-fixtures: ffmpeg has no dca encoder, skipping sample-dts.mkv" >&2
fi

echo "make-fixtures: subtitles"
node -e "
const fs=require('fs'); const {SRT,VTT}=require('$HERE/subtitles.js');
fs.writeFileSync('$OUT/sample.srt', SRT); fs.writeFileSync('$OUT/sample.vtt', VTT);
"

echo "make-fixtures: done"
ls -la "$OUT" "$OUT/hls" | sed 's/^/  /'
