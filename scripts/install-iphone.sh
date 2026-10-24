#!/usr/bin/env bash
# Build the app for the connected iPhone or iPad and install it there.
#
#   scripts/install-iphone.sh [--no-launch] [--release]
#
# --release installs the optimised build instead (build/iphone-rel.noindex). A Debug build is unoptimised, and SwiftUI screens full
# of cards run several times slower in it, which can look like a freeze.
#
# A Debug build, signed by Xcode with your BLUSION_DEVELOPMENT_TEAM, built into build/iphone.noindex (Spotlight skips folders named
# *.noindex, so the build product is never listed on the Mac as one more Blusion). Xcode may renew the provisioning profile
# with the Apple ID it is signed in with. With a free Apple ID the app stops opening after seven days: run this again.
# The device has to be paired, connected (cable or the same network) and unlocked. macOS + Xcode + xcodegen only.
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
CONFIG=Debug
WORK="build/iphone.noindex"
LOG="build/iphone-build.log"
for argument in "$@"; do
  case "$argument" in
    --no-launch) LAUNCH=0;;
    --release) CONFIG=Release; WORK="build/iphone-rel.noindex"; LOG="build/iphone-rel.log";;
    *) sed -n '2,12p' "$0" >&2; exit 64;;
  esac
done
APP="$ROOT/$WORK/Build/Products/$CONFIG-iphoneos/Blusion.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
fail() { echo "install-iphone: $1" >&2; exit 1; }
mkdir -p build

# Builds used to land in build/iphone, where Spotlight listed the product as a Mac app. Carry the cache over once.
if [[ -d build/iphone && ! -d "$WORK" ]]; then
  "$LSREGISTER" -u "$ROOT/build/iphone/Build/Products/Debug-iphoneos/Blusion.app" >/dev/null 2>&1 || true
  mv build/iphone "$WORK"
fi

# Exact target device, supplied outside source control.
TARGET_UDID="${BLUSION_IPHONE_UDID:-}"
[[ -n "$TARGET_UDID" ]] || fail "set BLUSION_IPHONE_UDID to the intended device UDID before installing"
TEAM="${BLUSION_DEVELOPMENT_TEAM:-}"
[[ -n "$TEAM" ]] || fail "set BLUSION_DEVELOPMENT_TEAM to your Apple Developer Team ID before installing"
DEVICES="$(mktemp)"
trap 'rm -f "$DEVICES"' EXIT
xcrun devicectl list devices --json-output "$DEVICES" >/dev/null 2>&1 || fail "could not list devices (is Xcode set up?)"
DEVICE="$(python3 - "$DEVICES" "$TARGET_UDID" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hardware, connection = device.get("hardwareProperties", {}), device.get("connectionProperties", {})
    if hardware.get("udid") == sys.argv[2] and connection.get("tunnelState") == "connected":
        print(hardware.get("udid", ""), device.get("deviceProperties", {}).get("name", "device"))
        break
PY
)"
UDID="${DEVICE%% *}"; NAME="${DEVICE#* }"
[[ -n "$UDID" ]] || fail "target device ($TARGET_UDID) is not connected: unlock it, keep it on this Mac's network or cable, and try again. No other device is used."

./scripts/enable-fallback.sh >/dev/null || fail "could not generate the Xcode project with the fallback engine (scripts/enable-fallback.sh)"
# The commit shown in Settings › About; "-dirty" when the working tree has uncommitted changes.
TAG="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD -- 2>/dev/null || TAG="$TAG-dirty"
echo "install-iphone: building $TAG for $NAME (log: $LOG)"
xcodebuild -project Blusion.xcodeproj -scheme Blusion -configuration "$CONFIG" -destination "id=$UDID" \
  -derivedDataPath "$WORK" -jobs 4 -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" BLUSION_BUILD_TAG="$TAG" build >"$LOG" 2>&1 || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
  grep -E 'error:' "$LOG" | sed -E "s#$ROOT/##g" | sort -u | head -40 >&2
  fail "BUILD FAILED (full log: $LOG)"
fi
[[ -d "$APP" ]] || fail "no build at $APP"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOG" 2>&1 || fail "could not install on $NAME (unlock it and try again; log: $LOG)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" 2>/dev/null)"
echo "install-iphone: Blusion $VERSION is on $NAME"
if [[ "$LAUNCH" == 1 ]]; then
  xcrun devicectl device process launch --device "$UDID" --terminate-existing app.blusion.player >>"$LOG" 2>&1 \
    || echo "install-iphone: installed, but could not open it (unlock $NAME and tap Blusion)" >&2
fi
