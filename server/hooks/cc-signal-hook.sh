#!/usr/bin/env bash
# CC 信号塔 hook bridge.
# Claude Code pipes the hook event JSON to this script on stdin. We forward it
# verbatim to the local server, which derives session status from it.
#
# Non-blocking by design: short timeout, errors swallowed, never affects Claude.
PORT="${CC_SIGNAL_PORT:-${1:-4317}}"
curl -s -m 1 \
  -X POST "http://127.0.0.1:${PORT}/hooks" \
  -H "content-type: application/json" \
  --data-binary @- \
  >/dev/null 2>&1 || true
exit 0
