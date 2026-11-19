#!/usr/bin/env bash
# ack-batch.sh — mark Telegram bridge batches as handled.
# Usage: ack-batch.sh <batch_id> [<batch_id> ...]
# Removes the batch(es) from ~/workspace/telegram-bridge/queue/pending.json
# so they are not re-woken after the 600s reclaim window. Call it after
# the main session has replied to (or deliberately skipped) a batch.
# The batch_ids arrive in the hook wake payload.
set -euo pipefail

QUEUE_DIR="$HOME/workspace/telegram-bridge/queue"
PENDING="$QUEUE_DIR/pending.json"

if [[ $# -eq 0 ]]; then
  echo "usage: ack-batch.sh <batch_id> [...]" >&2
  exit 2
fi
[[ -s "$PENDING" ]] || exit 0

ids_json="$(printf '%s\n' "$@" | jq -R . | jq -s -c .)"
tmp="$PENDING.tmp.$$"
if jq --argjson ids "$ids_json" \
  '[.[] | select(.batch_id as $b | ($ids | index($b)) == null)]' \
  "$PENDING" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$PENDING"
  chmod 600 "$PENDING" 2>/dev/null || true
else
  rm -f "$tmp"
  exit 1
fi
