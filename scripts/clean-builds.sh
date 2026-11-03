#!/usr/bin/env bash
# Permanently deletes old build output, so it does not pile up on the disk. Nothing goes to the Trash.
#
#   scripts/clean-builds.sh
#
# Deleted: everything in build/ except the two install caches (build/mac-install.noindex, build/iphone-rel.noindex) that keep the
# one-click installs fast; Xcode's own Blusion build in DerivedData (Xcode makes it again when you build there); Blusion copies left in
# the Trash by older installs; simulators Xcode no longer supports. The app's own data and caches (Application Support, Caches) are never
# touched, nor are other projects' builds.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
before=$(df -k / | awk 'NR==2 { print $4 }')

if [[ -d build ]]; then
  for item in build/* build/.[!.]*; do
    [[ -e "$item" ]] || continue
    case "$(basename "$item")" in
      mac-install.noindex|iphone-rel.noindex) ;;
      *) rm -rf "$item";;
    esac
  done
fi
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/Blusion-* 2>/dev/null
rm -rf "$HOME"/.Trash/Blusion* 2>/dev/null
xcrun simctl delete unavailable >/dev/null 2>&1 || true

after=$(df -k / | awk 'NR==2 { print $4 }')
freed=$(( (after - before) / 1024 ))
(( freed < 0 )) && freed=0
echo "clean-builds: freed ${freed} MB; $(( after / 1024 / 1024 )) GB free"
