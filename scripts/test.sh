#!/bin/bash
# Runs the WorkdayCore test suite. Works with full Xcode or with only the Command Line Tools
# (where the Swift Testing framework must be added to the search paths explicitly).
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
EXTRA=()
if [[ "$(xcode-select -p 2>/dev/null)" == "$CLT"* && -d "$CLT/Library/Developer/Frameworks/Testing.framework" ]]; then
  FW="$CLT/Library/Developer/Frameworks"
  EXTRA=(-Xswiftc -F -Xswiftc "$FW"
         -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib")
fi
exec swift test "${EXTRA[@]}" "$@"
