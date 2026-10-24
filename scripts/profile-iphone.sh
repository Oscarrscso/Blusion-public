#!/usr/bin/env bash
# Sample the running Blusion on the connected iPhone with Instruments' Time Profiler and print where its main thread spends its time.
#
#   scripts/profile-iphone.sh [seconds]        (default 12)
#
# Open Blusion on the phone first, and for a freeze: make it freeze, leave the phone unlocked on the frozen screen, then run this.
# The Debug build is the one that has symbols for Blusion's own code; a Release build shows SwiftUI's frames only. The trace is kept
# in build/profile.trace (open it in Instruments for the full call tree). macOS + Xcode only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SECONDS_TO_SAMPLE="${1:-12}"
fail() { echo "profile-iphone: $1" >&2; exit 1; }
mkdir -p build

DEVICES="$(mktemp)"
trap 'rm -f "$DEVICES"' EXIT
xcrun devicectl list devices --json-output "$DEVICES" >/dev/null 2>&1 || fail "could not list devices (is Xcode set up?)"
# Only the explicitly selected iPhone is profiled.
TARGET_UDID="${BLUSION_IPHONE_UDID:-}"
[[ -n "$TARGET_UDID" ]] || fail "set BLUSION_IPHONE_UDID to the intended device UDID before profiling"
UDID="$(python3 -I - "$DEVICES" "$TARGET_UDID" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    if hardware.get("udid") == sys.argv[2]:
        print(hardware.get("udid", ""))
        break
PY
)"
[[ -n "$UDID" ]] || fail "target device ($TARGET_UDID) is not paired with this Mac"
# Asking for the lock state wakes the connection, which Instruments needs.
xcrun devicectl device info lockState --device "$UDID" >/dev/null 2>&1 || true

rm -rf build/profile.trace build/profile.xml
echo "profile-iphone: sampling Blusion for ${SECONDS_TO_SAMPLE}s…"
xcrun xctrace record --device "$UDID" --attach Blusion --template "Time Profiler" --time-limit "${SECONDS_TO_SAMPLE}s" \
  --output build/profile.trace --no-prompt >build/profile-record.log 2>&1 \
  || { tail -n 8 build/profile-record.log >&2; fail "could not record (is Blusion open and the phone unlocked? log: build/profile-record.log)"; }
xcrun xctrace export --input build/profile.trace --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' \
  --output build/profile.xml >/dev/null 2>&1 || fail "could not read the trace"
python3 -I "$ROOT/scripts/summarize-profile.py" build/profile.xml
