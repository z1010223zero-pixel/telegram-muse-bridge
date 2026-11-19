#!/usr/bin/env bash
# watchdog.sh — Telegram bridge health check (ilink retrofit, 2026-11-17).
# Usage: watchdog.sh
# Prints one line and exits 0 when healthy, 1 when stale.
#   OK:        last heartbeat <30 min ago.
#   STALE:     no heartbeat file, or last heartbeat >=30 min ago.
#   RECOVERED: previously STALE, heartbeat fresh again (state kept in
#              watchdog-state.json next to the heartbeat).
# The cron that runs this only messages the user on STALE / RECOVERED.
set -euo pipefail

QUEUE_DIR="$HOME/workspace/telegram-bridge/queue"
HEARTBEAT="$QUEUE_DIR/heartbeat.json"
STATE_FILE="$QUEUE_DIR/watchdog-state.json"
STALE_SECS=1800

now="$(date +%s)"
last_ts=0
if [[ -s "$HEARTBEAT" ]]; then
  last_ts="$(jq -r '.ts // 0' "$HEARTBEAT" 2>/dev/null || echo 0)"
fi
age=$((now - last_ts))

prev="ok"
if [[ -s "$STATE_FILE" ]]; then
  prev="$(jq -r '.status // "ok"' "$STATE_FILE" 2>/dev/null || echo ok)"
fi

if (( age >= STALE_SECS )); then
  printf '{"status": "stale", "ts": %s}' "$now" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
  if [[ "$last_ts" == "0" ]]; then
    echo "STALE: no heartbeat file (bridge never polled successfully)"
  else
    echo "STALE: last heartbeat ${age}s ago"
  fi
  exit 1
fi

if [[ "$prev" == "stale" ]]; then
  printf '{"status": "ok", "ts": %s}' "$now" > "$STATE_FILE.tmp.$$" \
    && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
  echo "RECOVERED: heartbeat fresh again (was stale, last gap ${age}s)"
  exit 0
fi

printf '{"status": "ok", "ts": %s}' "$now" > "$STATE_FILE.tmp.$$" \
  && mv "$STATE_FILE.tmp.$$" "$STATE_FILE"
echo "OK: last heartbeat ${age}s ago"
exit 0
