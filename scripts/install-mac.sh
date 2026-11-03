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
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
fail() { echo "install-mac: $1" >&2; exit 1; }
# Old copies are deleted outright, not moved to the Trash: they are build products, and the app's data lives outside the bundle.
remove_bundle() {
  rm -rf "$1" || fail "could not delete $1"
}
mkdir -p "$WORK"

# Use the same advanced-player spec as iPhone. mpv supports Catalyst; AetherPlayer is linked only on iPhone/iPad.
./scripts/enable-fallback.sh >/dev/null || fail "could not generate the advanced-player Xcode project"
# A throwaway signing overlay, built without a provisioning profile.
cat > "$WORK/project.install.yml" <<YAML
include:
  - path: ../../project.fallback.generated.yml
targets:
  Blusion:
    settings:
      base:
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""
        # This project is generated two folders down, so build scripts find the repository from here.
        BLUSION_REPO_ROOT: "\$(SRCROOT)/../.."
YAML
xcodegen generate --spec "$WORK/project.install.yml" --project "$WORK" --quiet || fail "xcodegen failed"
REVISION="$(git rev-parse HEAD)"
TAG="$(git rev-parse --short HEAD)"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || TAG="$TAG-dirty"
echo "install-mac: building $TAG ($REVISION; log: $LOG)"
# This Mac's architecture only: a Release build is otherwise universal and compiles everything twice (arm64 and x86_64). No index
# store either: Xcode's editor never reads this DerivedData. Run at lower CPU priority so the Mac stays usable while it builds.
ARCH="$(uname -m)"
nice -n 10 xcodebuild -project "$WORK/Blusion.xcodeproj" -scheme Blusion -configuration Release \
  -destination "platform=macOS,variant=Mac Catalyst,arch=$ARCH" -derivedDataPath "$WORK/DerivedData" -jobs 4 \
  ONLY_ACTIVE_ARCH=YES ARCHS="$ARCH" COMPILER_INDEX_STORE_ENABLE=NO \
  BLUSION_BUILD_TAG="$TAG" BLUSION_SOURCE_REVISION="$REVISION" build >"$LOG" 2>&1 || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
  grep -E 'error:' "$LOG" | sed -E "s#$ROOT/##g" | sort -u | head -40 >&2
  fail "BUILD FAILED (full log: $LOG)"
fi
[[ -d "$APP" ]] || fail "no build at $APP"
python3 scripts/verify-player-build.py --app "$APP" --expected-revision "$REVISION" --expected-tag "$TAG" \
  || fail "compiled app verification failed; nothing was installed"

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
  remove_bundle "$DEST.installing"
fi
ditto "$APP" "$DEST.installing" || fail "could not write to /Applications"
if [[ -e "$DEST" ]]; then
  remove_bundle "$DEST"
fi
mv "$DEST.installing" "$DEST"

"$LSREGISTER" -dump 2>/dev/null | sed -n -E 's#^path: +(/.*/Blusion[^/]*\.app) \(0x[0-9a-f]+\)$#\1#p' | while read -r other; do
  [[ "$other" == "$DEST" ]] || "$LSREGISTER" -u "$other" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# Stray Mac copies are deleted, not only unlisted: the build product this install copied from, and any Mac Blusion.app left in Xcode's
# DerivedData or in this repo's build/ folder. Spotlight finds a copy on disk, so each one is a second "Blusion" until it is gone.
# Xcode's own build products go too (any platform: Xcode's Debug iPhone and Mac builds are both listed as Blusion). The iPhone install's
# build folder, build/iphone*.noindex, is left alone: that install builds it afresh each time.
for stray in "$APP" "$HOME"/Library/Developer/Xcode/DerivedData/Blusion-*/Build/Products/*/Blusion.app \
             "$ROOT"/build/*/DerivedData/Build/Products/*maccatalyst/Blusion.app; do
  [[ -e "$stray" && "$stray" != "$DEST" ]] || continue
  "$LSREGISTER" -u "$stray" >/dev/null 2>&1 || true
  remove_bundle "$stray"
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null)"
echo "install-mac: $DEST ($VERSION, ${IDENTITY:-ad hoc})"
[[ "$OPEN" == 0 ]] || open "$DEST"
