#!/usr/bin/env bash
# Put the Mac app in /Applications: a Release build of the Mac Catalyst app, and the only Blusion this Mac should list.
#
#   scripts/install-mac.sh [--no-open]
#
# Builds into build/mac-install.noindex (Spotlight skips folders named *.noindex, so the build product is never listed beside
# the installed app), quits a running Blusion, replaces /Applications/Blusion.app as a whole and opens it. Signed with this
# Mac's Apple Development certificate when it has one, so the Keychain and the privacy prompts recognise the app across
# installs; ad hoc otherwise. Every other Blusion that LaunchServices knows (old build products, copies in the Trash) is taken
# out of its list. Run it again to update the app. Never copy a build product into /Applications by hand and never open the
# app from build/: each copy that is launched is one more "Blusion" in Spotlight. macOS + Xcode + xcodegen only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "install-mac.sh needs macOS and Xcode" >&2; exit 2; }
OPEN=1
case "${1:-}" in
  "") ;;
  --no-open) OPEN=0;;
  *) sed -n '2,11p' "$0" >&2; exit 64;;
esac

WORK="build/mac-install.noindex"
APP="$ROOT/$WORK/DerivedData/Build/Products/Release-maccatalyst/Blusion.app"
DEST="/Applications/Blusion.app"
LOG="$WORK/build.log"
TRASH="$HOME/.Trash"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
fail() { echo "install-mac: $1" >&2; exit 1; }
trash_bundle() {
  local bundle="$1" label="$2" destination
  [[ -d "$TRASH" && -w "$TRASH" ]] || fail "Trash is unavailable; refusing to delete $bundle"
  destination="$TRASH/Blusion-$label-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM.app"
  mv "$bundle" "$destination" || fail "could not move $bundle to Trash"
}
mkdir -p "$WORK"

# The real project.yml, built without a provisioning profile. A throwaway overlay. No fallback engine here: the MPVKit versions the package allows (0.40.0, 0.41.0) fetch a Libuavs3d with no
# Mac Catalyst slice (docs/CLAUDE_HANDOFF.md, iOS-only exceptions), so the Mac app plays AVPlayer's formats only.
cat > "$WORK/project.install.yml" <<YAML
include:
  - path: ../../project.yml
targets:
  Blusion:
    settings:
      base:
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""
YAML
xcodegen generate --spec "$WORK/project.install.yml" --project "$WORK" --quiet || fail "xcodegen failed"
echo "install-mac: building (log: $LOG)"
xcodebuild -project "$WORK/Blusion.xcodeproj" -scheme Blusion -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$WORK/DerivedData" -jobs 4 BLUSION_BUILD_TAG="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" build >"$LOG" 2>&1 || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
  grep -E 'error:' "$LOG" | sed -E "s#$ROOT/##g" | sort -u | head -40 >&2
  fail "BUILD FAILED (full log: $LOG)"
fi
[[ -d "$APP" ]] || fail "no build at $APP"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    || fail "could not sign with $IDENTITY"
fi
codesign --verify --deep --strict "$APP" || fail "the build's signature does not verify"

# Quit the installed app before its files change underneath it.
if pkill -f "$DEST/Contents/MacOS/Blusion" >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$DEST/Contents/MacOS/Blusion" >/dev/null 2>&1 || break; sleep 0.5; done
fi
# A whole new bundle, moved into place: never files copied over the old one.
if [[ -e "$DEST.installing" ]]; then
  trash_bundle "$DEST.installing" "incomplete-install"
fi
ditto "$APP" "$DEST.installing" || fail "could not write to /Applications"
if [[ -e "$DEST" ]]; then
  trash_bundle "$DEST" "replaced"
fi
mv "$DEST.installing" "$DEST"

"$LSREGISTER" -dump 2>/dev/null | sed -n -E 's#^path: +(/.*/Blusion[^/]*\.app) \(0x[0-9a-f]+\)$#\1#p' | while read -r other; do
  [[ "$other" == "$DEST" ]] || "$LSREGISTER" -u "$other" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# Stray Mac copies are moved to Trash, not only unlisted: the build product this install copied from, and any Mac Blusion.app left in Xcode's
# DerivedData or in this repo's build/ folder. Spotlight finds a copy on disk, so each one is a second "Blusion" until it is gone.
# Xcode's own build products go too (any platform: Xcode's Debug iPhone and Mac builds are both listed as Blusion). The iPhone install's
# build folder, build/iphone*.noindex, is left alone: that install builds it afresh each time.
for stray in "$APP" "$HOME"/Library/Developer/Xcode/DerivedData/Blusion-*/Build/Products/*/Blusion.app \
             "$ROOT"/build/*/DerivedData/Build/Products/*maccatalyst/Blusion.app; do
  [[ -e "$stray" && "$stray" != "$DEST" ]] || continue
  "$LSREGISTER" -u "$stray" >/dev/null 2>&1 || true
  trash_bundle "$stray" "duplicate"
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null)"
echo "install-mac: $DEST ($VERSION, ${IDENTITY:-ad hoc})"
[[ "$OPEN" == 0 ]] || open "$DEST"
