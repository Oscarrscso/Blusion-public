#!/usr/bin/env bash
# Binary size delta of the opt-in fallback engine (PLAN M6: "binary size delta reported"). macOS + Xcode + xcodegen only.
#   ./scripts/size-report.sh        builds Release for the simulator twice (without / with MPVKit) and prints both .app sizes
# The number that matters for users is the App Store "App Thinning Size Report" from an archive; this is a quick relative measure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "size-report.sh needs macOS + Xcode" >&2; exit 2; }

build() {  # $1 spec file, $2 label
  xcodegen generate --spec "$1" --quiet
  rm -rf "build/size-$2"
  xcodebuild build -project Blusion.xcodeproj -scheme Blusion -configuration Release -sdk iphonesimulator \
    -derivedDataPath "build/size-$2" CODE_SIGNING_ALLOWED=NO -quiet
  du -sk "build/size-$2/Build/Products/Release-iphonesimulator/Blusion.app" | cut -f1
}

./scripts/enable-fallback.sh --generate-only >/dev/null
base="$(build project.yml base)"
with="$(build project.fallback.generated.yml fallback)"
xcodegen generate --spec project.yml --quiet   # leave the default project in place
printf 'Blusion.app (Release, simulator): base %s KB, with fallback engine %s KB, delta %s KB (%s MB)\n' \
  "$base" "$with" "$((with - base))" "$(( (with - base) / 1024 ))"
