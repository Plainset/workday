#!/bin/bash
# Builds a release of Workday and packages it for GitHub Releases:
#   dist/release/Workday-<version>-macOS.zip   (the .app, for drag-and-drop install)
#   dist/release/Workday-<version>-macOS.dmg   (disk image with an Applications shortcut)
#   dist/release/SHA256SUMS.txt
# Optional, only when credentials are present in the environment (never in the repo):
#   DEVELOPER_ID_APPLICATION  codesign identity, e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE            keychain profile created with `xcrun notarytool store-credentials`
# Without them the app is ad-hoc signed and NOT notarised (Gatekeeper requires right-click → Open).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
OUT="dist/release"
NAME="Workday-$VERSION-macOS"

./scripts/build_app.sh
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> Zip"
ditto -c -k --sequesterRsrc --keepParent dist/Workday.app "$OUT/$NAME.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] || { echo "NOTARY_PROFILE requires DEVELOPER_ID_APPLICATION" >&2; exit 1; }
  echo "==> Notarising app"
  xcrun notarytool submit "$OUT/$NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple dist/Workday.app
  rm "$OUT/$NAME.zip"
  ditto -c -k --sequesterRsrc --keepParent dist/Workday.app "$OUT/$NAME.zip"
fi

echo "==> Disk image"
STAGE="$(mktemp -d)"
cp -R dist/Workday.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Workday $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
rm -rf "$STAGE"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$OUT/$NAME.dmg"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT/$NAME.dmg"
  fi
fi

echo "==> Verify"
codesign --verify --strict --verbose=2 dist/Workday.app
hdiutil verify "$OUT/$NAME.dmg" >/dev/null
(cd "$OUT" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt && cat SHA256SUMS.txt)
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  spctl --assess --type execute --verbose dist/Workday.app
else
  echo "NOTE: not notarised (no NOTARY_PROFILE). See docs/RELEASING.md."
fi
echo "==> Release artefacts in $OUT"
