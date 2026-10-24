#!/bin/bash
# Measures Workday's CPU in each animation scenario, one fresh process per scenario, using demo data in a
# throwaway directory. Briefly shows a nearly transparent, click-through window. Requires a normal
# (non-full-screen) desktop Space so the window is actually rendered.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
BIN=.build/release/Workday
for scenario in menubar month-idle month-untouched month-live month-live-untouched month-motion year-idle year-motion; do
  DIR="$(mktemp -d)"
  WORKDAY_DATA_DIR="$DIR" "$BIN" --seed-demo --perf "$scenario" | tail -1
  rm -rf "$DIR"
done
