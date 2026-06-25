#!/usr/bin/env bash
# Package the built Agents-HUD.app into a drag-to-install DMG.
#   bash make-dmg.sh [out.dmg]    (run build-app.sh first)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Agents-HUD"
BUNDLE="$APP_NAME.app"
DMG="${1:-$APP_NAME.dmg}"

[ -d "$BUNDLE" ] || { echo "找不到 $BUNDLE，请先运行 build-app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-Applications target
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Sign the DMG too when a Developer ID is provided (so the installer itself has a
# valid signature before notarization).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

echo "==> created $(pwd)/$DMG"
