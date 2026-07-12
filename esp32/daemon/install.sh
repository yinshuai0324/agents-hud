#!/bin/bash
# AgentsHUD BLE 守护进程一键安装：venv + bleak + launchd 自启。
# 在 esp32/daemon 目录下运行：bash install.sh
set -euo pipefail

cd "$(dirname "$0")"
DAEMON_DIR="$(pwd)"
PLIST_LABEL="com.agentshud.ble"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

command -v python3 >/dev/null || { echo "需要 python3（brew install python3）"; exit 1; }

echo "==> 创建 venv 并安装 bleak"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q bleak

echo "==> 写入 launchd 服务（路径指向本机 $DAEMON_DIR）"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DAEMON_DIR/.venv/bin/python</string>
        <string>$DAEMON_DIR/agents_hud_ble.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/agents-hud-ble.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/agents-hud-ble.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "==> 完成。日志: tail -f /tmp/agents-hud-ble.log"
echo "    首次运行 macOS 会请求蓝牙权限，请允许（隐私与安全性 → 蓝牙）。"
