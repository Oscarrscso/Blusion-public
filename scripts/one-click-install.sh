#!/usr/bin/env bash
# What the "Install Blusion on Mac" and "Install Blusion on iPhone" apps run: bring main up to date, delete old builds, install, and say
# how it went in a notification. Xcode does not need to be open.
#
#   scripts/one-click-install.sh mac
#   BLUSION_IPHONE_UDID=<udid> scripts/one-click-install.sh iphone
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TARGET="${1:-}"
case "$TARGET" in
  mac) TITLE="Blusion for Mac";;
  iphone) TITLE="Blusion for iPhone";;
  *) echo "usage: scripts/one-click-install.sh mac|iphone" >&2; exit 64;;
esac
notify() { osascript -e "display notification \"$2\" with title \"$TITLE\" sound name \"$3\"" >/dev/null 2>&1 || true; }
started=$(date +%s)

# Fast-forward only, so local work is never discarded; a pull that cannot fast-forward installs what is here.
git pull --ff-only origin main || echo "one-click-install: could not fast-forward main; installing the local copy"
scripts/clean-builds.sh

if [[ "$TARGET" == mac ]]; then
  scripts/install-mac.sh
else
  scripts/install-iphone.sh --release
fi
status=$?
minutes=$(( ($(date +%s) - started + 59) / 60 ))
if [[ "$status" == 0 ]]; then
  notify "$TARGET" "Installed in about $minutes min." "Glass"
  echo "one-click-install: done in about $minutes min"
else
  notify "$TARGET" "Install failed. See the Terminal window." "Basso"
  echo "one-click-install: failed (exit $status)"
fi
exit "$status"
