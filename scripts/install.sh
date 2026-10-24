#!/bin/bash
# Installs dist/Workday.app into /Applications (or ~/Applications if not writable) and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d dist/Workday.app ]] || ./scripts/build_app.sh
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
if pgrep -x Workday >/dev/null; then
  echo "Quitting running Workday… (if the timer is running you'll be asked to stop it)"
  for id in io.github.plainset.workday local.workday.tracker; do
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 60); do pgrep -x Workday >/dev/null || break; sleep 1; done
  if pgrep -x Workday >/dev/null; then
    echo "Workday is still running (quit was cancelled?). Quit it, then run this script again." >&2
    exit 1
  fi
fi
rm -rf "$DEST/Workday.app"
cp -R dist/Workday.app "$DEST/"
echo "Installed to $DEST/Workday.app"
open "$DEST/Workday.app"
