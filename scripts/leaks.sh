#!/usr/bin/env bash
# Simulator half of the M8 leak pass (the host half is the LeakTests suites in PlayerKit and Features).
# Runs the UI flows while sampling the app with the macOS `leaks` tool (simulator processes are ordinary host processes),
# then fails if any sample reports leaked objects from Blusion's own code. macOS + Xcode only. UNVERIFIED until a Mac runs it
# (docs/MAC_FIRST_RUN.md). Apple framework internals show up as leaks too: the report keeps the stacks so a person can judge.
#   ./scripts/leaks.sh [interval-seconds]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "leaks.sh needs macOS and Xcode" >&2; exit 2; }
INTERVAL="${1:-8}"
OUT="build/leaks"; rm -rf "$OUT"; mkdir -p "$OUT"
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
phones = [s for k in sorted(d) if "iOS" in k for s in d[k] if "iPhone" in s["name"] and s.get("isAvailable", True)]
if not phones: sys.exit("leaks: no available iPhone simulator (install an iOS simulator runtime)")
print(phones[-1]["udid"])')" || exit 2

# Mock addon for the flows that need one.
node Tools/MockAddon/server.js --catalog-port 7101 --stream-port 7102 >"$OUT/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true; [[ -z "${SAMPLER_PID:-}" ]] || kill "$SAMPLER_PID" 2>/dev/null || true' EXIT
sleep 1

xcodegen generate --quiet || exit 1
xcrun simctl boot "$UDID" 2>/dev/null || true

# Sampler: every INTERVAL seconds, run `leaks` against the app if it is running.
(
  n=0
  while true; do
    sleep "$INTERVAL"
    pid="$(pgrep -x Blusion | head -n 1 || true)"
    [[ -n "$pid" ]] || continue
    n=$((n + 1))
    MallocStackLogging=1 leaks "$pid" >"$OUT/sample-$n.txt" 2>&1 || true
  done
) &
SAMPLER_PID=$!

SIMCTL_CHILD_MallocStackLogging=1 \
TEST_RUNNER_MallocStackLogging=1 \
TEST_RUNNER_MOCK_ADDON_CATALOG_URL="http://127.0.0.1:7101" \
TEST_RUNNER_MOCK_ADDON_STREAM_URL="http://127.0.0.1:7102" \
TEST_RUNNER_BLUSION_HAS_MEDIA_FIXTURES="$([[ -f Tools/MockAddon/fixtures/generated/sample.mp4 ]] && echo 1 || echo 0)" \
xcodebuild test -project Blusion.xcodeproj -scheme Blusion -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:BlusionUITests/AppFlowTests -only-testing:BlusionUITests/LibrarySettingsFlowTests CODE_SIGNING_ALLOWED=NO \
  >"$OUT/xcodebuild.log" 2>&1
TEST_STATUS=$?
kill "$SAMPLER_PID" 2>/dev/null
[[ "$TEST_STATUS" == 0 ]] || { tail -n 30 "$OUT/xcodebuild.log"; echo "leaks: UI tests failed" >&2; exit 1; }

samples=$(ls "$OUT"/sample-*.txt 2>/dev/null | wc -l | tr -d ' ')
echo "leaks: $samples samples taken while the UI flows ran (tests exit status $TEST_STATUS)"
[[ "$samples" -gt 0 ]] || { echo "leaks: no sample was taken (app never seen running); nothing proved" >&2; exit 1; }
# A leak counts against us only when a Blusion-owned frame is in its stack; framework-internal one-offs are listed but tolerated.
worst=0
for f in "$OUT"/sample-*.txt; do
  total="$(grep -Eo '[0-9]+ leaks? for' "$f" | head -n 1 | awk '{print $1}')"
  ours="$(grep 'Call stack:' "$f" | grep -cE 'Features|PlayerKit|StremioKit|Persistence|Blusion' || true)"
  echo "  $(basename "$f"): ${total:-0} leaks, ${ours:-0} leak stacks passing through our modules"
  [[ "${ours:-0}" -gt "$worst" ]] && worst="$ours"
done
if [[ "$worst" -gt 0 ]]; then
  echo "leaks: Blusion code appears in leak stacks; read $OUT/sample-*.txt" >&2
  exit 1
fi
echo "leaks: none attributed to Blusion code"
