#!/usr/bin/env bash
# Called automatically by the fallback scheme after SwiftPM resolves AetherEngine.
# Swift 6 rejects the upstream C-pointer capture in an actor-isolated closure.
# Patch Xcode's existing checkout; no separate local dependency is required.
set -euo pipefail
REVISION=a1a70cd63c1fef89cffcf0e8110456807d0fab05
CURSOR="${1:-${BUILD_DIR:-}}"
[[ -n "$CURSOR" ]] || { echo "prepare-aether: run through the generated Blusion scheme" >&2; exit 64; }
DEST=""
# Both normal builds and archives keep SourcePackages above their build folder.
while [[ -n "$CURSOR" && "$CURSOR" != / ]]; do
  for candidate in "$CURSOR/SourcePackages/checkouts/AetherEngine" "$CURSOR/SourcePackages/checkouts/aetherengine"; do
    if [[ -f "$candidate/Package.swift" ]]; then DEST="$candidate"; break; fi
  done
  [[ -z "$DEST" ]] || break
  CURSOR="$(dirname "$CURSOR")"
done
if [[ -z "$DEST" ]]; then
  # Scheme pre-actions run before SwiftPM resolves packages. On a clean checkout
  # there is nothing to patch yet, so allow dependency resolution to proceed.
  echo "prepare-aether: AetherEngine is not resolved yet; skipping compatibility patch" >&2
  exit 0
fi
[[ "$(git -C "$DEST" rev-parse HEAD)" == "$REVISION" ]] || {
  echo "prepare-aether: unexpected dependency revision; preserving $DEST unchanged" >&2; exit 1;
}
python3 - "$DEST" <<'PY'
from pathlib import Path
import stat,subprocess,sys
root=Path(sys.argv[1])
path='Sources/AetherEngine/AetherEngine.swift'
original=subprocess.check_output(['git','-C',str(root),'show','HEAD:'+path],text=True)
old_start='            let forcesSoftware = {\n                VideoRoutingPolicy.forcesSoftwareForUndecodableFormat('
old_end='            var routesSoftware = forcesSoftware()'
start=original.index(old_start)
end=original.index(old_end,start)+len(old_end)
old=original[start:end]
new='            // Ask the pure policy whether this format consults the hardware probe.\n            // A false injected verdict selects exactly those formats, preserving the\n            // DV Profile 5 exemption without capturing codecpar in a closure.\n            let consultsHardware = VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(\n                codecID: detectedCodecID,\n                dvProfile: presentsDolbyVisionBaseLayer ? nil : (correctedDVProfile ?? dvProfile),\n                canHardwareDecode: { false })\n            var routesSoftware = consultsHardware && !VTCapabilityProbe.canHardwareDecode(codecpar: codecpar)'
patched=original[:start]+new+original[end:]
retry='                routesSoftware = forcesSoftware()'
if patched.count(retry)!=1:
    raise SystemExit('prepare-aether: upstream retry probe differs; no patch applied')
patched=patched.replace(retry,'                routesSoftware = !VTCapabilityProbe.canHardwareDecode(codecpar: codecpar)',1)
previous=original.replace('let forcesSoftware = {\n                VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(',
                          'let forcesSoftware: @MainActor () -> Bool = {\n                VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(',1)
file=root/path
if file.read_text() not in (original,previous,patched):
    raise SystemExit('prepare-aether: dependency has local source changes; preserving them')
if file.read_text() != patched:
    file.chmod(file.stat().st_mode | stat.S_IWUSR)
    file.write_text(patched)
PY
echo "prepare-aether: AetherEngine 7.47.0 ($REVISION), synchronous decode-probe fix applied"
