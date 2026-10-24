#!/usr/bin/env bash
# One command gates every node (PLAN §3).
#
#   ./scripts/verify.sh              per-node run (skips the UI test target)
#   ./scripts/verify.sh milestone    milestone run (requires simulator UI tests unless ALLOW_HOST_ONLY=1)
#
# Steps, in order, stopping at the first failure:
#   1. swift test for StremioKit, PlayerKit, Persistence, Features (host-side, warnings as errors)
#   2. generate media, run the mock addon's own tests, start the mock and wait for its manifest, stop it on exit
#   3. xcodegen generate                         (macOS only)
#   4. xcodebuild test on the newest iPhone simulator, or iOS + Mac Catalyst builds when no runtime is installed
#   5. swiftlint --strict (if installed)
#   6. one-line summary, non-zero exit on failure
#
# Environment:
#   ALLOW_HOST_ONLY=1   let `milestone` pass without simulator tests (skipped checks remain in the summary)
#   SHOT=<node id>      after the app tests, save shots/<id>.png from the booted simulator
#   FALLBACK=1          build with the opt-in fallback engine (MPVKit, ADR-006) and run the MKV UI tests
#   CATALOG_PORT / STREAM_PORT   mock ports (default 7001 / 7002)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build

MODE="${1:-node}"
case "$MODE" in node|milestone) ;; *) echo "usage: $0 [node|milestone]" >&2; exit 64;; esac

CATALOG_PORT="${CATALOG_PORT:-7001}"
STREAM_PORT="${STREAM_PORT:-7002}"
PACKAGES=(StremioKit PlayerKit Persistence Features)
OS="$(uname -s)"
HAS_XCODE=0
if [[ "$OS" == "Darwin" ]] && command -v xcodebuild >/dev/null 2>&1; then HAS_XCODE=1; fi

SUMMARY=()
SKIPPED=()
MOCK_PID=""
START_TS=$(date +%s)

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() {
  local what="$1"
  printf '\n\033[31mverify: FAILED at %s\033[0m\n' "$what" >&2
  printf 'verify: %s | mode=%s | os=%s | FAIL (%s) | %ss\n' "$(basename "$ROOT")" "$MODE" "$OS" "$what" "$(( $(date +%s) - START_TS ))"
  exit 1
}

cleanup() {
  if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$ROOT/.mock-addon.pid"
}
trap cleanup EXIT

# ---- 1. host-side package tests ---------------------------------------------
log "1/6 swift test (host)"
command -v swift >/dev/null 2>&1 || fail "swift toolchain missing"
for pkg in "${PACKAGES[@]}"; do
  echo "-- $pkg"
  swift test --package-path "Packages/$pkg" -j 2 -Xswiftc -warnings-as-errors || fail "swift test $pkg"
done
SUMMARY+=("swift:${#PACKAGES[@]}pkgs")

# Apple-only sources (app target, app tests) cannot be compiled without Xcode. Parse them so syntax errors are caught on every host.
# Apple-only code inside packages sits behind #if canImport(...) and is parsed by the package builds above.
log "1b/6 project spec + syntax check (Apple-only app sources)"
python3 scripts/check-project-spec.py || fail "project spec check"
python3 scripts/extract-strings.py --check || fail "App/Localizable.xcstrings is missing strings (run scripts/extract-strings.py)"
APPLE_SRC=()
while IFS= read -r f; do [[ -f "$f" ]] && APPLE_SRC+=("$f"); done < <(git ls-files -co --exclude-standard -- 'App/*.swift' 'Tests/BlusionTests/*.swift' 'Tests/BlusionUITests/*.swift')
if [[ ${#APPLE_SRC[@]} -gt 0 ]]; then
  swiftc -parse "${APPLE_SRC[@]}" || fail "swiftc -parse (app sources)"
  echo "parsed ${#APPLE_SRC[@]} files"
  SUMMARY+=("parse:${#APPLE_SRC[@]}files")
fi

# ---- 2. mock addon ------------------------------------------------------------
log "2/6 mock addon"
command -v node >/dev/null 2>&1 || fail "node missing (need Node 18+)"
if command -v ffmpeg >/dev/null 2>&1; then
  ./Tools/MockAddon/make-fixtures.sh >/dev/null || fail "make-fixtures.sh"
else
  echo "ffmpeg not installed: media fixtures not generated (media-dependent tests will skip)"
  SKIPPED+=("fixtures(no ffmpeg)")
fi
(cd Tools/MockAddon && node --test --test-reporter=tap test/server.test.js) >build/mock-node-test.log 2>&1 \
  || { cat build/mock-node-test.log; fail "mock addon node tests"; }
grep -E '^# (tests|pass|fail|skipped)' build/mock-node-test.log | tr '\n' ' '; echo

node Tools/MockAddon/server.js --catalog-port "$CATALOG_PORT" --stream-port "$STREAM_PORT" >.mock-addon.log 2>&1 &
MOCK_PID=$!
echo "$MOCK_PID" > .mock-addon.pid
ready=0
for _ in $(seq 1 50); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CATALOG_PORT}/manifest.json" || true)"
  if [[ "$code" == "200" ]]; then ready=1; break; fi
  kill -0 "$MOCK_PID" 2>/dev/null || { cat .mock-addon.log; fail "mock addon exited early"; }
  sleep 0.2
done
[[ "$ready" == 1 ]] || { cat .mock-addon.log; fail "mock addon manifest did not answer 200"; }
echo "mock addon up: catalog :$CATALOG_PORT, stream :$STREAM_PORT (pid $MOCK_PID)"
export MOCK_ADDON_CATALOG_URL="http://127.0.0.1:${CATALOG_PORT}"
export MOCK_ADDON_STREAM_URL="http://127.0.0.1:${STREAM_PORT}"
HAS_MEDIA_FIXTURES=0
if [[ -f Tools/MockAddon/fixtures/generated/sample.mp4 && -f Tools/MockAddon/fixtures/generated/sample-ac3.mkv \
      && -f Tools/MockAddon/fixtures/generated/hls/index.m3u8 && -f Tools/MockAddon/fixtures/generated/hls/seg000.ts ]]; then HAS_MEDIA_FIXTURES=1; fi
HAS_DTS_FIXTURE=0
[[ -f Tools/MockAddon/fixtures/generated/sample-dts.mkv ]] && HAS_DTS_FIXTURE=1
SUMMARY+=("mock:up")

# ---- 3 + 4. Xcode ---------------------------------------------------------------
if [[ "$HAS_XCODE" == 1 ]]; then
  log "3/6 xcodegen"
  command -v xcodegen >/dev/null 2>&1 || fail "xcodegen missing (brew install xcodegen)"
  SPEC="project.yml"
  if [[ -n "${FALLBACK:-}" ]]; then
    ./scripts/enable-fallback.sh --generate-only || fail "enable-fallback"
    bash scripts/prepare-aether.sh || fail "prepare-aether"
    SPEC="project.fallback.generated.yml"
  fi
  xcodegen generate --spec "$SPEC" --quiet || fail "xcodegen generate ($SPEC)"
  SUMMARY+=("xcodegen${FALLBACK:+:fallback}")

  log "4/6 xcodebuild test"
  # Newest iOS runtime, first iPhone on it. Never hardcode a device name.
  UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
def ver(k):
    try: return tuple(int(x) for x in k.split("iOS-")[1].split("-"))
    except Exception: return ()
runtimes = sorted((k for k in d if "iOS" in k and any("iPhone" in s["name"] and s.get("isAvailable", True) for s in d[k])), key=ver, reverse=True)
if not runtimes: sys.exit(0)
phones = [s for s in d[runtimes[0]] if "iPhone" in s["name"] and s.get("isAvailable", True)]
pick = next((s for s in phones if "Pro" in s["name"] and "Max" not in s["name"]), phones[0])
print(pick["udid"])
')" || fail "listing iPhone simulators"
  if [[ -z "$UDID" ]]; then
    echo "SKIPPED (no iOS simulator runtime installed)"
    SKIPPED+=("simulator-tests")
    for target in device catalyst; do
      # The Mac build has no fallback engine (docs/CLAUDE_HANDOFF.md, iOS-only exceptions), so its leg runs only without FALLBACK=1.
      if [[ "$target" == "catalyst" && -n "${FALLBACK:-}" ]]; then
        echo "SKIPPED (Mac Catalyst is built without the fallback engine; run without FALLBACK=1 for the Mac build)"
        SKIPPED+=("build:catalyst:fallback")
        continue
      fi
      if [[ "$target" == "device" ]]; then DESTINATION='generic/platform=iOS'; else DESTINATION='platform=macOS,variant=Mac Catalyst'; fi
      echo "building: $DESTINATION"
      xcodebuild build -project Blusion.xcodeproj -scheme Blusion -destination "$DESTINATION" -jobs 2 CODE_SIGNING_ALLOWED=NO \
        >"build/verify-$target.log" 2>&1 || {
          grep -E 'error:' "build/verify-$target.log" | tail -n 30
          fail "xcodebuild $target (build/verify-$target.log)"
        }
      SUMMARY+=("build:$target")
    done
    if [[ "$MODE" == "milestone" && "${ALLOW_HOST_ONLY:-}" != "1" ]]; then
      fail "milestone needs simulator tests; no iOS simulator runtime installed (set ALLOW_HOST_ONLY=1 to accept skipped checks)"
    fi
  else
    echo "simulator: $UDID"
    xcrun simctl boot "$UDID" 2>/dev/null || true

    SKIP=()
    [[ "$MODE" == "node" ]] && SKIP=(-skip-testing:BlusionUITests)
    mkdir -p shots build
    RESULT="build/verify.xcresult"; rm -rf "$RESULT"
    # TEST_RUNNER_* variables are forwarded to the (simulator) test runner process.
    TEST_RUNNER_UITEST_SHOT_DIR="$ROOT/shots" \
    TEST_RUNNER_MOCK_ADDON_CATALOG_URL="$MOCK_ADDON_CATALOG_URL" \
    TEST_RUNNER_MOCK_ADDON_STREAM_URL="$MOCK_ADDON_STREAM_URL" \
    TEST_RUNNER_BLUSION_HAS_MEDIA_FIXTURES="$HAS_MEDIA_FIXTURES" \
    TEST_RUNNER_BLUSION_HAS_DTS_FIXTURE="$HAS_DTS_FIXTURE" \
    TEST_RUNNER_BLUSION_FALLBACK="${FALLBACK:-}" \
    xcodebuild test \
      -project Blusion.xcodeproj -scheme Blusion -jobs 2 \
      -destination "platform=iOS Simulator,id=$UDID" \
      -resultBundlePath "$RESULT" \
      ${SKIP[@]+"${SKIP[@]}"} \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
      CODE_SIGNING_ALLOWED=NO \
      | tee build/xcodebuild.log | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify --quieter || tail -n 60)
    [[ "${PIPESTATUS[0]}" == 0 ]] || fail "xcodebuild test"
    if [[ -n "${SHOT:-}" ]]; then
      xcrun simctl io "$UDID" screenshot "shots/${SHOT}.png" >/dev/null 2>&1 \
        && echo "screenshot: shots/${SHOT}.png" || echo "screenshot skipped (simulator not booted)"
    fi
    SUMMARY+=("xcodebuild:$MODE")
  fi

  if [[ "$MODE" == "milestone" ]]; then
    log "4b/6 xcodebuild archive (unsigned)"
    SPEC="$SPEC" ./scripts/archive.sh || fail "xcodebuild archive"
    SUMMARY+=("archive")
  fi
else
  log "3-4/6 xcodegen + xcodebuild"
  echo "SKIPPED (no Xcode on this host: $OS). Apple-only code is verified by the macOS CI job (ADR-002)."
  SKIPPED+=("xcodegen" "xcodebuild")
  if [[ "$MODE" == "milestone" && "${ALLOW_HOST_ONLY:-}" != "1" ]]; then
    fail "milestone run needs Xcode (set ALLOW_HOST_ONLY=1 for a host-layer-only run)"
  fi
fi

# ---- 5. swiftlint -----------------------------------------------------------------
log "5/6 swiftlint"
if command -v swiftlint >/dev/null 2>&1; then
  swiftlint --strict --quiet || fail "swiftlint --strict"
  SUMMARY+=("swiftlint")
else
  echo "swiftlint not installed: running scripts/lint-basic.sh (whitespace/newline subset) instead"
  ./scripts/lint-basic.sh || fail "lint-basic"
  SUMMARY+=("lint-basic")
  SKIPPED+=("swiftlint")
fi

# ---- 6. summary ---------------------------------------------------------------------
log "6/6 summary"
printf 'verify: %s | mode=%s | os=%s | PASS [%s]%s | %ss\n' \
  "$(basename "$ROOT")" "$MODE" "$OS" "${SUMMARY[*]}" \
  "$([[ ${#SKIPPED[@]} -gt 0 ]] && echo " | SKIPPED: ${SKIPPED[*]}")" "$(( $(date +%s) - START_TS ))"
