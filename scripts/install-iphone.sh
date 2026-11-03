#!/usr/bin/env bash
# Build the app for the connected iPhone or iPad and install it there.
#
#   scripts/install-iphone.sh [--no-launch] [--release] [--fresh]
#
# --release installs the optimised build instead (build/iphone-rel-<commit>.noindex). A Debug build is unoptimised, and SwiftUI screens full
# of cards run several times slower in it, which can look like a freeze.
#
# A Debug build, signed by Xcode with your team (BLUSION_DEVELOPMENT_TEAM or Config/Signing.xcconfig.local), built into build/iphone-<commit>.noindex (Spotlight skips folders named
# *.noindex, so the build product is never listed on the Mac as one more Blusion). Xcode may renew the provisioning profile
# with the Apple ID it is signed in with. With a free Apple ID the app stops opening after seven days: run this again.
# The device has to be paired once (Xcode > Devices, with "Connect via network" on). After that it is found on the same Wi-Fi: the app is
# built for any iPhone first, without the device, and then the script waits up to five minutes for the device, waking its network
# connection and retrying the install, so a locked or sleeping phone is waited for rather than refused. Xcode does not need to be open.
# macOS + Xcode + xcodegen only.
#
# Set BLUSION_IPHONE_UDID to the exact intended device. No device identifier is stored in the repository.
# The script refuses to choose a device automatically, preventing installation on the wrong device.
#
# The install is built with the fallback engine (MPVKit, ADR-006), so MKV, AVI, DTS, TrueHD and AV1 play in the app. The spec comes from
# scripts/enable-fallback.sh; project.yml itself stays the default build without third-party code.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "install-iphone.sh needs macOS and Xcode" >&2; exit 2; }
LAUNCH=1
FRESH=0
CONFIG=Debug
WORK="build/iphone.noindex"
LOG="build/iphone-build.log"
for argument in "$@"; do
  case "$argument" in
    --no-launch) LAUNCH=0;;
    --fresh) FRESH=1;;
    --release) CONFIG=Release; WORK="build/iphone-rel.noindex"; LOG="build/iphone-rel.log";;
    *) sed -n '2,12p' "$0" >&2; exit 64;;
  esac
done
# One build folder per configuration, reused, so each install compiles only what changed. The app's revision and tag are checked after the
# build (verify-player-build.py), so a stale product is never installed. --fresh builds from nothing in a folder of its own.
REVISION="$(git rev-parse HEAD)"
TAG="$(git rev-parse --short HEAD)"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || TAG="$TAG-dirty"
if [[ "$FRESH" == 1 ]]; then WORK="${WORK%.noindex}-$(date +%Y%m%d-%H%M%S)-$$.noindex"; fi
echo "install-iphone: source=$ROOT branch=$(git branch --show-current) revision=$REVISION tag=$TAG"
python3 scripts/verify-player-build.py || exit 1
APP="$ROOT/$WORK/Build/Products/$CONFIG-iphoneos/Blusion.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
fail() { echo "install-iphone: $1" >&2; exit 1; }
mkdir -p build

# Exact target device, supplied outside source control.
TARGET_UDID="${BLUSION_IPHONE_UDID:-}"
[[ -n "$TARGET_UDID" ]] || fail "set BLUSION_IPHONE_UDID to the intended device UDID before installing"
# Signing team, also kept outside source control: BLUSION_DEVELOPMENT_TEAM, else Config/Signing.xcconfig.local (the file Xcode reads).
TEAM_SETTING=()
if [[ -n "${BLUSION_DEVELOPMENT_TEAM:-}" ]]; then
  TEAM_SETTING=(DEVELOPMENT_TEAM="$BLUSION_DEVELOPMENT_TEAM")
elif ! grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Za-z0-9]+' Config/Signing.xcconfig.local 2>/dev/null; then
  fail "set BLUSION_DEVELOPMENT_TEAM, or DEVELOPMENT_TEAM in Config/Signing.xcconfig.local, to your Apple Developer Team ID before installing"
fi
DEVICES="$(mktemp)"
trap 'rm -f "$DEVICES"' EXIT
# The device's name when it is connected now, else nothing. "connected" is a live tunnel, over the cable or the network.
connected_device() {
  xcrun devicectl list devices --json-output "$DEVICES" >/dev/null 2>&1 || return 0
  python3 - "$DEVICES" "$TARGET_UDID" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hardware, connection = device.get("hardwareProperties", {}), device.get("connectionProperties", {})
    if hardware.get("udid") == sys.argv[2] and connection.get("tunnelState") == "connected":
        print(device.get("deviceProperties", {}).get("name", "iPhone"))
        break
PY
}
# Waits up to five minutes for the device, asking CoreDevice to connect to it on each try: a phone on the same Wi-Fi that is asleep or
# locked connects once it wakes or is unlocked.
wait_for_device() {
  local deadline=$(( $(date +%s) + 300 )) said=0 name
  while :; do
    name="$(connected_device)"
    if [[ -n "$name" ]]; then NAME="$name"; return 0; fi
    (( $(date +%s) >= deadline )) && return 1
    if (( said == 0 )); then
      echo "install-iphone: waiting for the iPhone on this Wi-Fi: unlock it and keep it awake"
      said=1
    fi
    xcrun devicectl device info details --device "$TARGET_UDID" >/dev/null 2>&1 || true
    sleep 3
  done
}
NAME="iPhone"

./scripts/enable-fallback.sh >/dev/null || fail "could not generate the Xcode project with the fallback engine (scripts/enable-fallback.sh)"
echo "install-iphone: building $TAG (log: $LOG)"
# Built for any iPhone, so the device need not be reachable yet. No index store: Xcode's editor never reads this build. Lower CPU priority
# keeps the Mac usable while it builds.
nice -n 10 xcodebuild -project Blusion.xcodeproj -scheme Blusion -configuration "$CONFIG" -destination 'generic/platform=iOS' \
  -derivedDataPath "$WORK" -jobs 4 -allowProvisioningUpdates COMPILER_INDEX_STORE_ENABLE=NO ${TEAM_SETTING[@]+"${TEAM_SETTING[@]}"} \
  BLUSION_BUILD_TAG="$TAG" BLUSION_SOURCE_REVISION="$REVISION" build >"$LOG" 2>&1 || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
  grep -E 'error:' "$LOG" | sed -E "s#$ROOT/##g" | sort -u | head -40 >&2
  fail "BUILD FAILED (full log: $LOG)"
fi
[[ -d "$APP" ]] || fail "no build at $APP"
python3 scripts/verify-player-build.py --app "$APP" --expected-revision "$REVISION" --expected-tag "$TAG" \
  || fail "compiled app verification failed; nothing was installed"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

installed=0
for attempt in 1 2 3; do
  wait_for_device || fail "the iPhone ($TARGET_UDID) did not connect within five minutes: unlock it, check it is on this Mac's Wi-Fi, and run this again"
  if xcrun devicectl device install app --device "$TARGET_UDID" "$APP" >>"$LOG" 2>&1; then installed=1; break; fi
  echo "install-iphone: install attempt $attempt did not finish; trying again"
  sleep 3
done
[[ "$installed" == 1 ]] || fail "could not install on $NAME after three attempts (log: $LOG)"
UDID="$TARGET_UDID"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null)"
echo "install-iphone: Blusion $VERSION ($TAG, $REVISION) is on $NAME"
if [[ "$LAUNCH" == 1 ]]; then
  xcrun devicectl device process launch --device "$UDID" --terminate-existing app.blusion.player >>"$LOG" 2>&1 \
    || echo "install-iphone: installed, but could not open it (unlock $NAME and tap Blusion)" >&2
fi
