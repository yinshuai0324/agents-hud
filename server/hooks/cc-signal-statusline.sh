#!/usr/bin/env bash
# CC 信号塔 statusLine bridge.
# Claude Code pipes its statusLine JSON to this script on stdin. That payload
# carries the REAL plan usage (rate_limits.five_hour / seven_day) which Claude
# fetched from /api/oauth/usage. We forward it to the local server, then print a
# concise status line back so the user still gets a useful statusline.
PORT="${CC_SIGNAL_PORT:-${1:-4317}}"
INPUT="$(cat)"

# Forward to the server (non-blocking, short timeout, errors swallowed).
printf '%s' "$INPUT" | curl -s -m 1 -X POST "http://127.0.0.1:${PORT}/statusline" \
  -H 'content-type: application/json' --data-binary @- >/dev/null 2>&1 || true

# Render a compact line for Claude Code's status bar.
printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
parts = []
model = (d.get("model") or {}).get("display_name")
if model:
    parts.append(model)
rl = (d.get("rate_limits") or {}).get("five_hour") or {}
pct = rl.get("used_percentage")
if pct is not None:
    parts.append("5H " + str(round(pct)) + "%")
wd = (d.get("rate_limits") or {}).get("seven_day") or {}
wpct = wd.get("used_percentage")
if wpct is not None:
    parts.append("7D " + str(round(wpct)) + "%")
print("  ".join(parts))
' 2>/dev/null || true
