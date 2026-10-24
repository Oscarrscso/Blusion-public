#!/usr/bin/env bash
# Look at the app on a Mac that has no iOS simulator: build the Mac Catalyst variant, open it on a route, save a PNG of its window.
#
#   scripts/snapshot.sh <route> <out.png> [--mac] [--delay <seconds>] [--size <WxH>] [--env KEY=VALUE]... [--no-build]
#
#   <route>   a LaunchRoute: home, discover, library, search, search:<query>, detail:<type>:<id>, streams:<type>:<id>,
#             settings, addons, widgets (the last three open the Settings sheet), gallery, gallery:<section>, player
#   --delay   seconds to wait for content before the picture is taken (default 8; network-backed screens need time)
#   --mac     the Mac app as it ships (Mac idiom, sidebar) in a 1280x800 window, instead of the phone-sized stand-in
#   --size    window size in points (default 402x874, an iPhone 17; 1280x800 with --mac)
#   --env     extra environment for the app, e.g. --env BLUSION_DEMO_DATA=1 (sample library and watch progress)
#   --no-build  reuse the last build
#
# The app runs with in-memory stores (BLUSION_UITEST=1: nothing touches the Keychain or saved data) and with the default
# addon seeded (BLUSION_SEED_DEFAULTS=1), so screens show real catalogs. The picture is drawn by the app itself
# (App/DebugSnapshot.swift), so no Screen Recording permission is needed. Catalyst lays the app out like a narrow iPad:
# close to an iPhone, not identical. A sheet is a window of its own on the Mac, so a route that opens one gives a picture
# of just the sheet, at the Mac's sheet size. Everything generated lands in build/ (git-ignored).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ $# -ge 2 ]] || { sed -n '2,16p' "$0" >&2; exit 64; }
ROUTE="$1"; OUT="$2"; shift 2
DELAY=8; SIZE=""; BUILD=1; MAC=0; EXTRA_ENV=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac) MAC=1; shift;;
    --delay) DELAY="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --env) EXTRA_ENV+=(--env "$2"); shift 2;;
    --no-build) BUILD=0; shift;;
    *) echo "snapshot: unknown option $1" >&2; exit 64;;
  esac
done
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
# Two flavours, built side by side: the phone stand-in runs in the iPad idiom (families 1,2), where a narrow window lays out
# like an iPhone; --mac keeps the shipping setting (Mac idiom).
if [[ "$MAC" == 1 ]]; then FLAVOR="catalyst-mac"; FAMILY="1,2,6"; : "${SIZE:=1280x800}"; else FLAVOR="catalyst"; FAMILY="1,2"; : "${SIZE:=402x874}"; fi
[[ -n "$SIZE" ]] || SIZE="402x874"
mkdir -p "$(dirname "$OUT")" "build/$FLAVOR-proj"

PROJECT="build/$FLAVOR-proj/Blusion.xcodeproj"
# Spotlight skips folders named *.noindex, so the build product is never listed as one more Blusion app.
DERIVED="build/$FLAVOR.noindex"
APP="$ROOT/$DERIVED/Build/Products/Debug-maccatalyst/Blusion.app"
LOG="build/$FLAVOR-build.log"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Builds used to land in build/$FLAVOR under the real bundle id. Carry the cache over once and drop that product.
if [[ -d "build/$FLAVOR" && ! -d "$DERIVED" ]]; then
  "$LSREGISTER" -u "$ROOT/build/$FLAVOR/Build/Products/Debug-maccatalyst/Blusion.app" >/dev/null 2>&1 || true
  mv "build/$FLAVOR" "$DERIVED" && rm -rf "$DERIVED/Build/Products"
fi

if [[ "$BUILD" == 1 ]]; then
  # The real project.yml with ad-hoc signing and this flavour's device families. A throwaway overlay. A bundle id of its own
  # keeps a snapshot run away from the installed app (scripts/install-mac.sh): the two would otherwise share preferences, and
  # the window size forced below would become the size the real app opens at.
  cat > "build/$FLAVOR-proj/project.catalyst.yml" <<YAML
include:
  - path: ../../project.yml
targets:
  Blusion:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.blusion.player.snapshot
        TARGETED_DEVICE_FAMILY: "$FAMILY"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""
YAML
  xcodegen generate --spec "build/$FLAVOR-proj/project.catalyst.yml" --project "build/$FLAVOR-proj" --quiet || { echo "snapshot: xcodegen failed" >&2; exit 1; }
  xcodebuild -project "$PROJECT" -scheme Blusion -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$DERIVED" -jobs 4 build >"$LOG" 2>&1
  if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG"; then
    echo "snapshot: BUILD FAILED (full log: $LOG)" >&2
    grep -E 'error:' "$LOG" | sed -E "s#$ROOT/##g" | sort -u | head -40 >&2
    exit 1
  fi
fi
[[ -d "$APP" ]] || { echo "snapshot: no build at $APP (run without --no-build)" >&2; exit 1; }

rm -f "$OUT"
# Show the preview so Catalyst navigation animations finish. -n starts a fresh instance.
open -n "$APP" \
  --env BLUSION_UITEST=1 --env BLUSION_SEED_DEFAULTS=1 \
  --env "BLUSION_ROUTE=$ROUTE" --env "BLUSION_SNAPSHOT=$OUT" --env "BLUSION_SNAPSHOT_DELAY=$DELAY" --env "BLUSION_WINDOW_SIZE=$SIZE" \
  ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} || { echo "snapshot: could not launch $APP" >&2; exit 1; }

# The app exits by itself once the picture is written. Give it the delay plus a margin, then stop waiting.
DEADLINE=$(( $(date +%s) + ${DELAY%.*} + 30 ))
while [[ ! -s "$OUT" && $(date +%s) -lt $DEADLINE ]]; do sleep 0.5; done
sleep 0.5
pkill -f "$APP/Contents/MacOS/Blusion" >/dev/null 2>&1 || true
# Launching registered this build with LaunchServices. Take it out again, so it is not offered as an app or for blusion:// links.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
if [[ -s "$OUT" ]]; then
  echo "snapshot: $OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | awk '/pixel/{printf "%s ", $2}'| sed 's/ $//; s/ /x/'))"
else
  echo "snapshot: the app did not write $OUT within $(( ${DELAY%.*} + 30 )) s" >&2
  exit 1
fi
