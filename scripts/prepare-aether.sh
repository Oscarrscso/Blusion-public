#!/usr/bin/env bash
# Prepare the existing AetherEngine release with synchronous decode probes.
# Swift 6 rejects the upstream C-pointer capture in an actor-isolated closure.
# Source stays in ignored build output; no third-party binaries are committed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION=a1a70cd63c1fef89cffcf0e8110456807d0fab05
DEST="$ROOT/build/dependencies/AetherEngine"
mkdir -p "$ROOT/build/dependencies"
if [[ ! -d "$DEST" ]]; then
  git clone --depth 1 --branch 7.47.0 https://github.com/superuser404notfound/AetherEngine.git "$DEST"
fi
[[ "$(git -C "$DEST" rev-parse HEAD)" == "$REVISION" ]] || {
  echo "prepare-aether: unexpected dependency revision; preserving $DEST unchanged" >&2; exit 1;
}
python3 - "$DEST" <<'PY'
from pathlib import Path
import subprocess,sys
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
file.write_text(patched)
PY
echo "prepare-aether: AetherEngine 7.47.0 ($REVISION), synchronous decode-probe fix applied"
