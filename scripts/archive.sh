#!/usr/bin/env bash
# Unsigned release archive of the app (PLAN M8: "xcodebuild archive succeeds"), then checks on what was archived.
# Signing, provisioning and upload are the human's steps: docs/RELEASE.md. macOS + Xcode + xcodegen only.
#   ./scripts/archive.sh                 # default build
#   SPEC=project.fallback.generated.yml ./scripts/archive.sh   # with the opt-in fallback engine
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "archive.sh needs macOS and Xcode" >&2; exit 2; }
SPEC="${SPEC:-project.yml}"
ARCHIVE="build/Blusion.xcarchive"
mkdir -p build
rm -rf "$ARCHIVE"

xcodegen generate --spec "$SPEC" --quiet
xcodebuild archive \
  -project Blusion.xcodeproj -scheme Blusion -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | tee build/archive.log | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify --quieter || tail -n 40)
[[ "${PIPESTATUS[0]}" == 0 ]] || { echo "archive: xcodebuild archive failed (build/archive.log)" >&2; exit 1; }

APP="$ARCHIVE/Products/Applications/Blusion.app"
fail() { echo "archive: $1" >&2; exit 1; }
[[ -d "$APP" ]] || fail "no Blusion.app in the archive"
PLIST="$APP/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }

BUNDLE_ID="$(plist CFBundleIdentifier)"; NAME="$(plist CFBundleDisplayName)"
echo "archived: $BUNDLE_ID ($NAME) $(plist CFBundleShortVersionString) ($(plist CFBundleVersion))"
shopt -s nocasematch
[[ "$BUNDLE_ID $NAME $(basename "$APP")" != *stremio* ]] || fail "app name or bundle id contains 'Stremio' (PLAN section 1)"
shopt -u nocasematch
[[ -z "$(plist NSAppTransportSecurity:NSAllowsArbitraryLoads || true)" ]] || fail "NSAllowsArbitraryLoads must not be set"
[[ "$(plist NSAppTransportSecurity:NSAllowsLocalNetworking)" == "true" ]] || fail "NSAllowsLocalNetworking missing"
[[ "$(plist UIBackgroundModes || true)" == *audio* ]] || fail "UIBackgroundModes lacks audio"
[[ -n "$(plist NSLocalNetworkUsageDescription || true)" ]] || fail "NSLocalNetworkUsageDescription missing"
[[ -f "$APP/PrivacyInfo.xcprivacy" ]] || fail "PrivacyInfo.xcprivacy was not bundled"
[[ -f "$APP/Assets.car" ]] || fail "asset catalog (app icon) was not compiled"
echo "archive: OK ($(du -sh "$APP" | cut -f1) app bundle) -> $ARCHIVE"
