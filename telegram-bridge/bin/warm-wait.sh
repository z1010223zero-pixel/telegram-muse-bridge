#!/usr/bin/env bash
# warm-wait.sh — block until a new queued batch lands, or time runs out.
#
# Called by the responder worker AFTER it has replied directly to a batch.
# The worker stays warm so a follow-up message inside the window is
# answered by this same (already hot) worker instead of a fresh cold one.
#
# Usage: warm-wait.sh --worker-id <id> --idle-secs 180 --total-secs 600
#   [--queue-dir <dir>]   (queue dir defaults to
#   ~/workspace/telegram-bridge/queue)
#
# Exit 0: new queued batches found. Their JSON array is printed on stdout,
#   and they are claimed (marked inflight, woken_at=now) so the poll script
#   will not wake a duplicate worker for them.
# Exit 2: idle timeout — no new batch within --idle-secs.
# Exit 3: total budget (--total-secs since the warm marker was created)
#   exhausted.
# Exit 1: internal error (bad args, unreadable queue).
#
# While waiting it maintains queue/warm.json (worker_id, started_at,
# last_heartbeat) refreshed every ~5s. The poll script treats a marker
# with a heartbeat fresher than 60s as a live warm worker and skips its
# wake. On timeout exit the marker is removed, but only if it still
# belongs to this worker id. If this process is killed, the marker simply
# goes stale and the poll script resumes waking — no batch is lost, it
# stays queued until acked.
set -euo pipefail

WORKER_ID=""
IDLE_SECS=180
TOTAL_SECS=600
QUEUE_DIR="${HOME}/workspace/telegram-bridge/queue"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker-id) WORKER_ID="$2"; shift 2 ;;
    --idle-secs) IDLE_SECS="$2"; shift 2 ;;
    --total-secs) TOTAL_SECS="$2"; shift 2 ;;
    --queue-dir) QUEUE_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$WORKER_ID" ]] || { echo "--worker-id is required" >&2; exit 1; }
[[ "$IDLE_SECS" =~ ^[0-9]+$ ]] && [[ "$TOTAL_SECS" =~ ^[0-9]+$ ]] || { echo "secs must be integers" >&2; exit 1; }

PENDING="$QUEUE_DIR/pending.json"
WARM="$QUEUE_DIR/warm.json"
mkdir -p "$QUEUE_DIR"
chmod 700 "$QUEUE_DIR" 2>/dev/null || true
[[ -s "$PENDING" ]] || { printf '%s' '[]' > "$PENDING.tmp.$$" && mv "$PENDING.tmp.$$" "$PENDING"; chmod 600 "$PENDING" 2>/dev/null || true; }

# started_at persists across calls in the marker, so the total budget is
# enforced even if the caller miscounts. A marker from another worker id
# is never overwritten.
now_s="$(date +%s)"
started_at="$now_s"
if [[ -s "$WARM" ]]; then
  prev_id="$(jq -r '.worker_id // ""' "$WARM" 2>/dev/null || printf '')"
  prev_started="$(jq -r '.started_at // 0' "$WARM" 2>/dev/null || printf '0')"
  if [[ "$prev_id" == "$WORKER_ID" ]] && [[ "$prev_started" =~ ^[0-9]+$ ]] && (( prev_started > 0 )); then
    started_at="$prev_started"
  fi
fi

write_marker() {
  local ts="$1"
  printf '{"worker_id": "%s", "started_at": %s, "last_heartbeat": %s}' \
    "$WORKER_ID" "$started_at" "$ts" > "$WARM.tmp.$$" && mv "$WARM.tmp.$$" "$WARM"
  chmod 600 "$WARM" 2>/dev/null || true
}

remove_marker_if_mine() {
  if [[ -s "$WARM" ]]; then
    local cur; cur="$(jq -r '.worker_id // ""' "$WARM" 2>/dev/null || printf '')"
    if [[ "$cur" == "$WORKER_ID" ]]; then rm -f "$WARM"; fi
  fi
}

# Claim queued batches: mark inflight so the poll script will not wake a
# duplicate worker for them, and print them for the caller.
claim_queued() {
  local now="$1"
  local claimed
  claimed="$(jq -c --argjson now "$now" '[.[] | select(.status == "queued")]' "$PENDING" 2>/dev/null || printf '')"
  if [[ -z "$claimed" ]]; then return 1; fi
  if [[ "$(printf '%s' "$claimed" | jq -r 'length')" == "0" ]]; then return 1; fi
  local tmp="$PENDING.tmp.$$"
  if jq --argjson now "$now" \
      '[.[] | if .status == "queued" then .status = "inflight" | .woken_at = $now else . end]' \
      "$PENDING" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$PENDING"; chmod 600 "$PENDING" 2>/dev/null || true
  else
    rm -f "$tmp"; return 1
  fi
  printf '%s\n' "$claimed"
  return 0
}

write_marker "$now_s"
call_start="$now_s"

while true; do
  now_s="$(date +%s)"
  write_marker "$now_s"
  if claimed="$(claim_queued "$now_s")"; then
    printf '%s\n' "$claimed"
    exit 0
  fi
  if (( now_s - started_at >= TOTAL_SECS )); then
    remove_marker_if_mine
    exit 3
  fi
  if (( now_s - call_start >= IDLE_SECS )); then
    remove_marker_if_mine
    exit 2
  fi
  sleep 5
done
