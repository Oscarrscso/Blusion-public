#!/usr/bin/env bash
# Runs the screenshot-producing UI tests on a small phone, a Pro Max phone and an iPad, so layouts can be reviewed at each size
# (PLAN M3 acceptance). Devices are resolved from `xcrun simctl list` by family, never by hard-coded name.
#   ./scripts/screenshots.sh            writes shots/<device-class>/<name>.png
# Needs macOS + Xcode + the mock addon; starts and stops the mock itself.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "screenshots.sh needs macOS + Xcode" >&2; exit 2; }

CATALOG_PORT="${CATALOG_PORT:-7001}"; STREAM_PORT="${STREAM_PORT:-7002}"
if command -v ffmpeg >/dev/null 2>&1; then
  ./Tools/MockAddon/make-fixtures.sh >/dev/null || exit 1
else
  echo "ffmpeg not installed: playback screenshots will skip unless media fixtures already exist"
fi
HAS_MEDIA_FIXTURES=0
if [[ -f Tools/MockAddon/fixtures/generated/sample.mp4 && -f Tools/MockAddon/fixtures/generated/sample-ac3.mkv \
      && -f Tools/MockAddon/fixtures/generated/hls/index.m3u8 && -f Tools/MockAddon/fixtures/generated/hls/seg000.ts ]]; then HAS_MEDIA_FIXTURES=1; fi
node Tools/MockAddon/server.js --catalog-port "$CATALOG_PORT" --stream-port "$STREAM_PORT" >.mock-addon.log 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:${CATALOG_PORT}/manifest.json" >/dev/null && break; sleep 0.2; done
curl -sf "http://127.0.0.1:${CATALOG_PORT}/manifest.json" >/dev/null || { echo "screenshots: mock addon did not start" >&2; exit 1; }

xcodegen generate --quiet || exit 1

# class -> "name regex|exclude regex"; first match on the newest iOS runtime wins.
pick() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
want, exclude = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["devices"]
def ver(k):
    try: return tuple(int(x) for x in k.split("iOS-")[1].split("-"))
    except Exception: return ()
for runtime in sorted((k for k in d if "iOS" in k), key=ver, reverse=True):
    for s in d[runtime]:
        if s.get("isAvailable", True) and re.search(want, s["name"]) and not (exclude and re.search(exclude, s["name"])):
            print(s["udid"] + "|" + s["name"]); sys.exit(0)
sys.exit(1)' "$1" "$2"
}

status=0
devices=0
for spec in "small-phone|iPhone.*SE|" "pro-max-phone|iPhone.*Pro Max|" "ipad|iPad|mini"; do
  class="${spec%%|*}"; rest="${spec#*|}"; want="${rest%%|*}"; exclude="${rest#*|}"
  device="$(pick "$want" "$exclude")" || { echo "no simulator for $class, skipping"; continue; }
  udid="${device%%|*}"; name="${device#*|}"
  devices=$((devices + 1))
  echo "== $class: $name"
  out="$ROOT/shots/$class"; mkdir -p "$out"
  xcrun simctl boot "$udid" 2>/dev/null || true
  TEST_RUNNER_UITEST_SHOT_DIR="$out" \
  TEST_RUNNER_MOCK_ADDON_CATALOG_URL="http://127.0.0.1:${CATALOG_PORT}" \
  TEST_RUNNER_MOCK_ADDON_STREAM_URL="http://127.0.0.1:${STREAM_PORT}" \
  TEST_RUNNER_BLUSION_HAS_MEDIA_FIXTURES="$HAS_MEDIA_FIXTURES" \
  xcodebuild test -project Blusion.xcodeproj -scheme Blusion -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:BlusionUITests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -n 15 || status=1
done
[[ "$devices" -gt 0 ]] || { echo "screenshots: no matching iOS simulators; no screenshots were tested" >&2; exit 2; }
exit $status
