#!/usr/bin/env bash
# Fresh simulator build + compiled-bundle audit + actual player interaction tests.
# FALLBACK=1 also compiles and exercises the installed iPhone's fallback configuration.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || { echo "verify-player-ui: needs macOS, Xcode and an iOS simulator" >&2; exit 2; }
REVISION="$(git rev-parse HEAD)"
TAG="$(git rev-parse --short HEAD)"
PHASE="${PLAYER_VERIFICATION_PHASE:-all}"
case "$PHASE" in all|release|simulator) ;; *) echo "invalid player verification phase: $PHASE" >&2; exit 64;; esac
mkdir -p "$ROOT/build/player-verification.noindex"
WORK="$(mktemp -d "$ROOT/build/player-verification.noindex/run-${FALLBACK:-0}-$PHASE.XXXXXXXX")"
RESULT="$WORK/player.xcresult"
mkdir -p "$WORK/shots"
python3 scripts/verify-player-build.py
if [[ "${FALLBACK:-0}" == 1 ]]; then bash scripts/enable-fallback.sh; else xcodegen generate --quiet; fi
if [[ "$PHASE" != release ]]; then
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
runtimes=json.load(sys.stdin)["devices"]
for runtime in sorted(runtimes, reverse=True):
 if "iOS" not in runtime: continue
 phones=[d for d in runtimes[runtime] if "iPhone" in d["name"] and d.get("isAvailable",True)]
 if phones:
  print(phones[0]["udid"]); break
')"
[[ -n "$UDID" ]] || { echo "verify-player-ui: no installed iPhone simulator" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
bash Tools/MockAddon/make-fixtures.sh
node Tools/MockAddon/server.js --catalog-port 7001 --stream-port 7002 >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in {1..50}; do
 if curl --fail --silent http://127.0.0.1:7001/manifest.json >/dev/null; then break; fi
 sleep 0.2
done
curl --fail --silent http://127.0.0.1:7001/manifest.json >/dev/null
fi
if [[ "$PHASE" != simulator ]]; then
xcodebuild build -project Blusion.xcodeproj -scheme Blusion -configuration Release \
 -destination 'generic/platform=iOS' -derivedDataPath "$WORK/Release" -jobs 3 \
 BLUSION_BUILD_TAG="$TAG" BLUSION_SOURCE_REVISION="$REVISION" CODE_SIGNING_ALLOWED=NO \
 >"$WORK/release.log" 2>&1 || { grep -E "error:|Testing failed:" "$WORK/release.log" | head -60 || true; tail -60 "$WORK/release.log"; exit 1; }
python3 scripts/verify-player-build.py --app "$WORK/Release/Build/Products/Release-iphoneos/Blusion.app" \
 --expected-revision "$REVISION" --expected-tag "$TAG"
if [[ "${FALLBACK:-0}" != 1 ]]; then
 xcodebuild build -project Blusion.xcodeproj -scheme Blusion -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$WORK/Catalyst" -jobs 3 \
  BLUSION_BUILD_TAG="$TAG" BLUSION_SOURCE_REVISION="$REVISION" CODE_SIGNING_ALLOWED=NO \
  >"$WORK/catalyst.log" 2>&1 || { grep -E "error:|Testing failed:" "$WORK/catalyst.log" | head -60 || true; tail -60 "$WORK/catalyst.log"; exit 1; }
 python3 scripts/verify-player-build.py --app "$WORK/Catalyst/Build/Products/Release-maccatalyst/Blusion.app" \
  --expected-revision "$REVISION" --expected-tag "$TAG"
fi
fi
if [[ "$PHASE" != release ]]; then
TESTS=(-only-testing:BlusionTests/PlayerPresentationTests
       -only-testing:BlusionUITests/PlaybackFlowTests/testNativeSegmentsKeepPanelAndVideoStableAcrossTabsAndRotation
       -only-testing:BlusionUITests/PlaybackFlowTests/testSubtitlesAppearAtTheirCueTimes)
if [[ "${FALLBACK:-0}" == 1 ]]; then TESTS+=(-only-testing:BlusionUITests/FallbackFlowTests/testMKVWithAC3Plays); fi
TEST_RUNNER_UITEST_SHOT_DIR="$WORK/shots" \
TEST_RUNNER_MOCK_ADDON_CATALOG_URL=http://127.0.0.1:7001 \
TEST_RUNNER_MOCK_ADDON_STREAM_URL=http://127.0.0.1:7002 \
TEST_RUNNER_BLUSION_HAS_MEDIA_FIXTURES=1 \
TEST_RUNNER_BLUSION_FALLBACK="${FALLBACK:-}" \
xcodebuild test -project Blusion.xcodeproj -scheme Blusion -configuration Debug \
 -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$WORK/DerivedData" -resultBundlePath "$RESULT" -jobs 3 \
 -parallel-testing-enabled NO \
 "${TESTS[@]}" \
 BLUSION_BUILD_TAG="$TAG" BLUSION_SOURCE_REVISION="$REVISION" CODE_SIGNING_ALLOWED=NO \
 >"$WORK/xcodebuild.log" 2>&1 || { xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/shots/failures" --only-failures 2>/dev/null || true; grep -E "\\.swift:[0-9]+:.*error:|Test Case.*failed|Testing failed:" "$WORK/xcodebuild.log" | head -60 || true; tail -60 "$WORK/xcodebuild.log"; exit 1; }
APP="$WORK/DerivedData/Build/Products/Debug-iphonesimulator/Blusion.app"
python3 scripts/verify-player-build.py --app "$APP" --expected-revision "$REVISION" --expected-tag "$TAG"
INSTALLED="$(xcrun simctl get_app_container "$UDID" app.blusion.player app)"
python3 scripts/verify-player-build.py --app "$INSTALLED" --expected-revision "$REVISION" --expected-tag "$TAG"
fi
echo "verify-player-ui: PASS ($PHASE; $REVISION; screenshots and xcresult in $WORK)"
