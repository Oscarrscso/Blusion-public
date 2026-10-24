#!/usr/bin/env bash
# Turns on the opt-in fallback engine (MPVKit, ADR-006) by generating project.fallback.generated.yml from project.yml:
# every line marked `#fallback# ` is un-commented. Then generates the Xcode project from it.
#
#   ./scripts/enable-fallback.sh                 write the spec and run xcodegen on it
#   ./scripts/enable-fallback.sh --generate-only write the spec only (verify.sh uses this when FALLBACK=1)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="project.fallback.generated.yml"

sed 's/#fallback# //' project.yml > "$OUT"
grep -q 'FallbackPlayer' "$OUT" || { echo "enable-fallback: project.yml has no #fallback# markers" >&2; exit 1; }
echo "enable-fallback: wrote $OUT"

[[ "${1:-}" == "--generate-only" ]] && exit 0
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 2; }
xcodegen generate --spec "$OUT" --quiet
echo "enable-fallback: Blusion.xcodeproj now includes FallbackPlayer (MPVKit). Build and run as usual."
