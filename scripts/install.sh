#!/bin/bash
# Installs dist/Workday.app into /Applications (or ~/Applications if not writable) and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d dist/Workday.app ]] || ./scripts/build_app.sh
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
if pgrep -x Workday >/dev/null; then
  echo "Quitting running Workday…"
  osascript -e 'tell application id "local.workday.tracker" to quit' || true
  sleep 2
fi
rm -rf "$DEST/Workday.app"
cp -R dist/Workday.app "$DEST/"
echo "Installed to $DEST/Workday.app"
open "$DEST/Workday.app"
