#!/usr/bin/env bash
# Wire-compat check: diff /api/snapshot between two AgentsHUD servers reading
# the same ~/.claude (typically Node on 4317 vs the Swift port on 4318).
#
#   scripts/wirecheck.sh [portA] [portB] [rounds]
#
# Typical setup (Node on 4317, Swift build on 4318):
#   CC_SIGNAL_PORT=4318 mac/.build/debug/AgentsHUD --headless &
#   echo 4318 > ~/.claude/agents-hud/mirror-port   # hooks/statusline double-send
#   scripts/wirecheck.sh 4317 4318 20
#   rm ~/.claude/agents-hud/mirror-port            # stop mirroring when done
#
# Normalization before diffing:
#   - `ts` removed (always differs)
#   - `today` removed from the strict diff (each server rescans on its own 30s
#     timer, so live values are phase-skewed by design; printed for eyeballing.
#     Exact today-math parity is covered by the golden fixture unit tests.)
#   - resetInMinutes rounded to ±1 min buckets
#   - burnRatePerMin / outputTokensPerSec compared at 1% tolerance
#   - sessions[].lastActivity bucketed to the second (hooks bump it live)
set -euo pipefail

A_PORT="${1:-4317}"
B_PORT="${2:-4318}"
ROUNDS="${3:-1}"
TOKEN="${CC_SIGNAL_TOKEN:-}"

command -v jq >/dev/null || { echo "wirecheck: jq is required" >&2; exit 2; }

fetch() {
  local port="$1"
  local url="http://127.0.0.1:${port}/api/snapshot"
  if [[ -n "$TOKEN" ]]; then url="${url}?token=${TOKEN}"; fi
  curl -fsS -m 5 "$url"
}

# Normalize volatile fields so semantically-equal snapshots diff clean.
normalize() {
  jq -S '
    def fuzz1pct: if . == null then null elif . == 0 then 0 else (. / (if (.|fabs) > 100 then (.|fabs) * 0.01 else 1 end) | round) end;
    del(.ts)
    | del(.today)
    | .usage5h.resetInMinutes = ((.usage5h.resetInMinutes // 0) / 2 | round)
    | .usage5h.burnRatePerMin = (.usage5h.burnRatePerMin | fuzz1pct)
    | (if .usage7d != null then .usage7d.resetInMinutes = ((.usage7d.resetInMinutes // 0) / 2 | round) else . end)
    | .outputTokensPerSec = (.outputTokensPerSec | fuzz1pct)
    | .sessions = (.sessions | map(.lastActivity = ((.lastActivity // 0) / 1000 | round)) | sort_by(.id))
  '
}

fail=0
for ((i = 1; i <= ROUNDS; i++)); do
  a_raw=$(fetch "$A_PORT") || { echo "wirecheck: port $A_PORT unreachable" >&2; exit 2; }
  b_raw=$(fetch "$B_PORT") || { echo "wirecheck: port $B_PORT unreachable" >&2; exit 2; }
  a=$(printf '%s' "$a_raw" | normalize)
  b=$(printf '%s' "$b_raw" | normalize)
  if diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") >/tmp/wirecheck.diff 2>&1; then
    echo "[round $i/$ROUNDS] OK  (today A: $(printf '%s' "$a_raw" | jq -c .today)  B: $(printf '%s' "$b_raw" | jq -c .today))"
  else
    echo "[round $i/$ROUNDS] MISMATCH:"
    cat /tmp/wirecheck.diff
    fail=1
  fi
  if ((i < ROUNDS)); then sleep 3; fi
done

exit "$fail"
