#!/usr/bin/env bash
# Render the app icon from source (AppIconView) and build AppIcon.icns.
# Run this only when the icon design changes; AppIcon.icns is committed and
# build-app.sh just copies it in.
set -euo pipefail
cd "$(dirname "$0")"

MASTER="$(mktemp -d)/icon_1024.png"
echo "==> rendering 1024² master"
swift build -c release >/dev/null
.build/release/AgentsHUD --render-icon "$MASTER"

echo "==> building iconset"
SET="AppIcon.iconset"
rm -rf "$SET"; mkdir "$SET"
render() { sips -z "$1" "$1" "$MASTER" --out "$SET/$2" >/dev/null; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
cp "$MASTER" "$SET/icon_512x512@2x.png"

iconutil -c icns -o AppIcon.icns "$SET"
rm -rf "$SET"
echo "==> created $(pwd)/AppIcon.icns"
