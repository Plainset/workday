#!/bin/bash
# Dependency policy check. Workday ships with zero third-party packages, so there is no third-party code that
# could carry known vulnerabilities. This check fails if a dependency is added without review.
set -euo pipefail
cd "$(dirname "$0")/.."
deps="$(swift package show-dependencies --format json | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("dependencies", [])))')"
if [[ "$deps" != "0" ]]; then
  echo "error: $deps third-party package dependencies found. Review licences and advisories, then update this check." >&2
  swift package show-dependencies
  exit 1
fi
if [[ -f Package.resolved ]]; then
  echo "error: Package.resolved present but no dependencies are expected." >&2
  exit 1
fi
echo "OK: no third-party Swift package dependencies (system frameworks only: AppKit, SwiftUI, SQLite3, ServiceManagement, UserNotifications)."
