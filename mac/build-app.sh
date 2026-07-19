#!/usr/bin/env bash
# Build the SwiftPM executable and wrap it into a menu-bar .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Agents-HUD"
BUNDLE="$APP_NAME.app"
BUNDLE_ID="com.ooimi.agents.hud.mac"
# Version: env override (CI passes the tag) > repo-root VERSION file > 0.0.0.
if [[ -z "${VERSION:-}" && -f ../VERSION ]]; then
  VERSION="$(tr -d '[:space:]' < ../VERSION)"
fi
VERSION="${VERSION:-0.0.0}"
# Sparkle appcast feed + EdDSA public key (optional; without them the app
# builds fine but in-app update checking is disabled).
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/yinshuai0324/agents-hud/releases/latest/download/appcast.xml}"
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-}"

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
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundles (hook scripts etc.) — Bundle.module looks for these
# in Contents/Resources of the main bundle.
for rb in "$BIN_DIR"/*.bundle; do
  [ -d "$rb" ] || continue
  cp -R "$rb" "$BUNDLE/Contents/Resources/"
done

# Sparkle.framework from the SwiftPM binary artifact. The binary references it
# via @rpath, so embed it and point an rpath at Contents/Frameworks.
SPARKLE_FW="$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -1 || true)"
if [[ -n "$SPARKLE_FW" ]]; then
  echo "==> embedding Sparkle.framework"
  cp -R "$SPARKLE_FW" "$BUNDLE/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
else
  echo "!! Sparkle.framework not found under .build/artifacts — updater disabled" >&2
fi

# Bundled esptool (firmware flashing). Optional: present once fetched by
# scripts/fetch-esptool.sh; the app degrades gracefully without it.
if [ -d Vendor/esptool ]; then
  echo "==> bundling esptool"
  cp -R Vendor/esptool "$BUNDLE/Contents/Resources/esptool"
fi

# App icon (committed; regenerate with make-icon.sh when the design changes).
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Sparkle keys are only written when configured, so a keyless local build
# doesn't ship a feed URL it can't verify.
SPARKLE_PLIST=""
if [[ -n "$SPARKLE_ED_PUBLIC_KEY" ]]; then
  SPARKLE_PLIST=$(cat <<SPK
  <key>SUFeedURL</key>              <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>          <string>$SPARKLE_ED_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key> <true/>
SPK
)
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
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
  <!-- BLE provisioning of ESP32 dials. -->
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>用于扫描并配置 AgentsHUD 桌面表盘（下发 WiFi 配置）。</string>
  <!-- macOS 15+: serving Android/ESP32 over the LAN + Bonjour advertising. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>用于向局域网内的手机 App 和桌面表盘推送状态数据。</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_agentshud._tcp</string>
  </array>
$SPARKLE_PLIST
</dict>
</plist>
PLIST

# Sign: a real Developer ID + hardened runtime when CODESIGN_IDENTITY is set
# (CI release — required for Apple notarization); ad-hoc otherwise (local dev).
#
# Nested-first order matters: Sparkle's XPC services and helpers must be signed
# before the framework, and the framework before the app. `--deep` would sign
# top-down and break notarization.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> codesign (Developer ID + hardened runtime): $CODESIGN_IDENTITY"
  sign() { codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$@"; }

  FW="$BUNDLE/Contents/Frameworks/Sparkle.framework"
  if [ -d "$FW" ]; then
    for xpc in "$FW"/Versions/B/XPCServices/*.xpc; do
      [ -d "$xpc" ] && sign "$xpc"
    done
    [ -f "$FW/Versions/B/Autoupdate" ] && sign "$FW/Versions/B/Autoupdate"
    [ -d "$FW/Versions/B/Updater.app" ] && sign "$FW/Versions/B/Updater.app"
    sign "$FW"
  fi
  # Embedded Mach-O tools must be signed explicitly for notarization.
  if [ -d "$BUNDLE/Contents/Resources/esptool" ]; then
    find "$BUNDLE/Contents/Resources/esptool" -type f -perm +111 | while read -r tool; do
      sign "$tool"
    done
  fi
  sign "$BUNDLE"
  codesign --verify --strict --verbose=2 "$BUNDLE"
else
  codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true
fi

echo "==> done: $(pwd)/$BUNDLE (version $VERSION)"
echo "    open \"$BUNDLE\"   # 或拖到「应用程序」"
