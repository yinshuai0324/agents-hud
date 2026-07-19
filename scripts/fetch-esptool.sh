#!/usr/bin/env bash
# Fetches the official esptool standalone binaries (macOS arm64 + x86_64) into
# mac/Vendor/esptool/, where build-app.sh bundles them into the .app.
#
#   scripts/fetch-esptool.sh [version]
#
# The binaries are Espressif's PyInstaller builds — the same tool as `pip
# install esptool`, no Python required at runtime.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# v4.9.0: the last v4-series CLI (write_flash / no_reset spellings, which
# EsptoolRunner.swift uses). v5 renamed commands; bump deliberately, not blindly.
VER="${1:-v4.9.0}"
DEST="mac/Vendor/esptool"
mkdir -p "$DEST"

fetch() {
  local platform="$1" out="$2"
  local url="https://github.com/espressif/esptool/releases/download/${VER}/esptool-${VER}-${platform}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  echo "==> $url"
  curl -fsSL "$url" -o "$tmp/esptool.tar.gz"
  tar -xzf "$tmp/esptool.tar.gz" -C "$tmp"
  # The tarball contains esptool/esptool (plus espefuse etc. we don't need).
  local bin
  bin="$(find "$tmp" -type f -name esptool | head -1)"
  [ -n "$bin" ] || { echo "esptool binary not found in tarball" >&2; exit 1; }
  cp "$bin" "$DEST/$out"
  chmod +x "$DEST/$out"
  rm -rf "$tmp"
}

fetch "macos-arm64" "esptool-arm64"
fetch "macos-amd64" "esptool-x86_64"

echo "$VER" > "$DEST/VERSION"
echo "==> done: $DEST"
ls -la "$DEST"
