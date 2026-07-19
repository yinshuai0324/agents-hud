#!/usr/bin/env bash
# Agents-HUD hook bridge.
# Claude Code pipes the hook event JSON to this script on stdin. We forward it
# verbatim to the local server, which derives session status from it.
#
# Non-blocking by design: short timeout, errors swallowed, never affects Claude.
#
# Debug: if ~/.claude/agents-hud/mirror-port exists, the payload is also sent
# to that port (used by scripts/wirecheck.sh to compare two server builds).
PORT="${CC_SIGNAL_PORT:-${1:-4317}}"
INPUT="$(cat)"

send() {
  printf '%s' "$INPUT" | curl -s -m 1 \
    -X POST "http://127.0.0.1:${1}/hooks" \
    -H "content-type: application/json" \
    --data-binary @- \
    >/dev/null 2>&1 || true
}

send "$PORT"
MIRROR_FILE="$HOME/.claude/agents-hud/mirror-port"
if [ -f "$MIRROR_FILE" ]; then
  MIRROR_PORT="$(cat "$MIRROR_FILE" 2>/dev/null)"
  [ -n "$MIRROR_PORT" ] && [ "$MIRROR_PORT" != "$PORT" ] && send "$MIRROR_PORT"
fi
exit 0
