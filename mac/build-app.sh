#!/usr/bin/env bash
# Build the SwiftPM executable and wrap it into a menu-bar .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Agents-HUD"
BUNDLE="$APP_NAME.app"
BUNDLE_ID="com.ooimi.agents.hud.mac"
VERSION="${VERSION:-0.1.0}"          # CI passes the tag version in

# UNIVERSAL=1 builds an arm64 + x86_64 fat binary (used in CI so the DMG runs on
# both Apple Silicon and Intel Macs); local dev builds the host arch only.
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  echo "==> swift build -c release (universal)"
  swift build -c release --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  echo "==> swift build -c release"
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi
BIN="$BIN_DIR/AgentsHUD"

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>         <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <!-- Menu-bar-only agent app: no Dock icon. -->
  <key>LSUIElement</key>             <true/>
  <!-- Allow the plain ws://127.0.0.1 connection to the local server. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>
</dict>
</plist>
PLIST

# Sign: a real Developer ID + hardened runtime when CODESIGN_IDENTITY is set
# (CI release — required for Apple notarization); ad-hoc otherwise (local dev).
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> codesign (Developer ID + hardened runtime): $CODESIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$CODESIGN_IDENTITY" "$BUNDLE"
  codesign --verify --deep --strict "$BUNDLE"
else
  codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
fi

echo "==> done: $(pwd)/$BUNDLE"
echo "    open \"$BUNDLE\"   # 或拖到「应用程序」"
