#!/usr/bin/env bash
# Line coverage for one Swift package (M1 acceptance: >= 90% for StremioKit).
#   ./scripts/coverage.sh StremioKit [threshold-percent]
# Works on macOS (xcrun llvm-cov) and Linux (llvm-cov from the Swift toolchain).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${1:?package name, e.g. StremioKit}"
THRESHOLD="${2:-90}"
DIR="$ROOT/Packages/$PKG"

mkdir -p "$ROOT/build"
LOG="$(mktemp "$ROOT/build/coverage-$PKG.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
swift test --package-path "$DIR" --enable-code-coverage -Xswiftc -warnings-as-errors >"$LOG" 2>&1 || { cat "$LOG"; echo "coverage: tests failed" >&2; exit 1; }
rm -f "$LOG"
PROFDATA="$(swift test --package-path "$DIR" --show-codecov-path | sed 's/\.json$/.profdata/')"
[[ -f "$PROFDATA" ]] || PROFDATA="$(dirname "$(swift test --package-path "$DIR" --show-codecov-path)")/default.profdata"
BIN_DIR="$(swift build --package-path "$DIR" --show-bin-path)"
# Linux builds one aggregate <Pkg>PackageTests.xctest; newer macOS toolchains name the bundle after the test target.
BIN="$BIN_DIR/${PKG}PackageTests.xctest"
if [[ ! -e "$BIN" ]]; then
  BIN="$(find "$BIN_DIR" -maxdepth 1 -name '*.xctest' | head -n 1)"
fi
[[ -n "$BIN" && -e "$BIN" ]] || { echo "coverage: no test binary under $BIN_DIR" >&2; exit 1; }
if [[ -d "$BIN/Contents/MacOS" ]]; then
  BIN="$BIN/Contents/MacOS/$(basename "$BIN" .xctest)"
fi
LLVM_COV=(llvm-cov); command -v llvm-cov >/dev/null 2>&1 || LLVM_COV=(xcrun llvm-cov)

# Sources only: exclude tests and checkouts.
"${LLVM_COV[@]}" report "$BIN" -instr-profile "$PROFDATA" \
  -ignore-filename-regex='(\.build|Tests|StremioKitTestSupport|/usr/)' | tee "$ROOT/coverage-$PKG.txt" | tail -n 40

PCT="$("${LLVM_COV[@]}" export "$BIN" -instr-profile "$PROFDATA" -summary-only \
  -ignore-filename-regex='(\.build|Tests|StremioKitTestSupport|/usr/)' | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%.2f" % d["data"][0]["totals"]["lines"]["percent"])')"
echo "coverage: $PKG lines = ${PCT}% (threshold ${THRESHOLD}%)"
python3 -c "import sys; sys.exit(0 if float('$PCT') >= float('$THRESHOLD') else 1)" || { echo "coverage below threshold" >&2; exit 1; }
