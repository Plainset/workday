#!/bin/bash
# Builds a universal (arm64 + x86_64 when possible) release Workday.app into dist/.
# Requires only the Xcode Command Line Tools (or Xcode). No network access needed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="${VERSION:-$(cat VERSION)}"
# Build number = commit count (CI checks out full history so this matches local builds).
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/dist/Workday.app"

echo "==> Building arm64 release"
swift build -c release --triple arm64-apple-macosx14.0
BINARIES=("$ROOT/.build/arm64-apple-macosx/release/Workday")
if [[ "${ARM64_ONLY:-0}" != "1" ]]; then
  echo "==> Building x86_64 release"
  if swift build -c release --triple x86_64-apple-macosx14.0; then
    BINARIES+=("$ROOT/.build/x86_64-apple-macosx/release/Workday")
  elif [[ "${REQUIRE_UNIVERSAL:-0}" == "1" ]]; then
    echo "error: x86_64 build failed and REQUIRE_UNIVERSAL=1" >&2
    exit 1
  else
    echo "!! x86_64 build failed; producing an arm64-only app" >&2
  fi
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Workday"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

# Developer ID signing when an identity is provided (e.g. DEVELOPER_ID_APPLICATION="Developer ID Application:
# Name (TEAMID)"); otherwise an ad-hoc signature. Hardened runtime either way. No secrets are stored in the repo.
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "==> Signing with Developer ID: $DEVELOPER_ID_APPLICATION"
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$APP"
else
  echo "==> Signing (ad-hoc; set DEVELOPER_ID_APPLICATION for a Developer ID signature)"
  codesign --force --sign - --options runtime --timestamp=none "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/Workday"
echo "==> Done: $APP"
