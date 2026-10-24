#!/bin/bash
# Runs tests, builds the release app and renders snapshots, saving logs under evidence/.
set -uo pipefail
cd "$(dirname "$0")/.."
REV="$(git rev-parse --short HEAD)"
OUT="evidence/latest"
rm -rf "$OUT"; mkdir -p "$OUT"
echo "revision: $(git rev-parse HEAD)" > "$OUT/REVISION.txt"
git status --short >> "$OUT/REVISION.txt"
{ sw_vers; swift --version 2>&1; xcode-select -p; uname -m; } > "$OUT/environment.txt"
./scripts/test.sh > "$OUT/test.log" 2>&1; echo "test exit: $?" >> "$OUT/test.log"
./scripts/build_app.sh > "$OUT/build.log" 2>&1; echo "build exit: $?" >> "$OUT/build.log"
dist/Workday.app/Contents/MacOS/Workday --snapshot "$OUT/snapshots" > "$OUT/snapshot.log" 2>&1
# Never publish machine-specific paths: rewrite the checkout path and home directory in logs.
for f in "$OUT"/*.log "$OUT/environment.txt"; do
  sed -i '' -e "s#$(pwd)#.#g" -e "s#$HOME#~#g" "$f"
done
grep -E "Test run|✘" "$OUT/test.log" | tail -5
tail -3 "$OUT/build.log"
echo "Evidence for $REV in $OUT"
