#!/usr/bin/env bash
# Telegram bridge poll script — ilink-style durability retrofit (2026-11-17).
#
# Compared with the pre-retrofit version:
#  - Messages are landed to a durable queue (pending.json) BEFORE the
#    offset advances, and only woken after landing. A failed wake leaves
#    the batch queued; the next round re-wakes it. No more silent loss
#    when a worker/handoff dies between offset advance and delivery.
#  - Inbound dedupe by message_id / callback_id (seen.json, last 500):
#    a re-delivered update is never queued twice.
#  - Wake is at-least-once: batches are marked "inflight" BEFORE wake is
#    called (wake() exits the process on success, so nothing after it
#    runs) and stay queued until the main session acks them
#    (ack-batch.sh). A batch inflight for >600s without an ack is
#    re-queued and re-woken. The main session dedupes re-deliveries via
#    handled_message_ids in the per-chat state file (see the skill doc).
#  - Heartbeat (heartbeat.json) is touched on every successful fetch,
#    so the watchdog cron can tell a dead bridge from a quiet one.
#  - Warm-wait (2026-11-17): after replying directly, the responder worker
#    keeps queue/warm.json fresh (heartbeat <60s) while it waits up to 180s
#    idle / 600s total for follow-ups. (Hook worker sessions last ~600s —
#    measured 2026-11-17: a 200s probe survived, a 900s probe did not, and
#    a repeated-short-sleep probe died in its 4th 150s round, ~600s in.) While the marker is fresh this
#    script lands new batches but skips the wake, so no duplicate worker
#    starts; the warm worker claims the queued batches itself
#    (bin/warm-wait.sh). A stale marker means the warm worker is gone and
#    the wake proceeds normally. Batches stay queued until acked either way.
#
# Queue files live in ~/workspace/telegram-bridge/queue/ (0700, files 0600).
# The responder worker replies directly and warm-waits; the payload carries
# batch_ids so the worker (or the main session, for escalated batches) can
# ack via ack-batch.sh.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

HELPER="$HOME/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py"
# 模板说明：把 YOUR_BOT_USERNAME 换成你自己 Bot 的用户名（不带 @）。
BOT_USERNAME="YOUR_BOT_USERNAME"

QUEUE_DIR="$HOME/workspace/telegram-bridge/queue"
mkdir -p "$QUEUE_DIR"
chmod 700 "$QUEUE_DIR" 2>/dev/null || true
PENDING="$QUEUE_DIR/pending.json"    # [{batch_id, landed_at, woken_at, status, messages, callbacks}]
SEEN="$QUEUE_DIR/seen.json"          # [{key, ts}] cap 500
HEARTBEAT="$QUEUE_DIR/heartbeat.json" # {ts} touched on every successful fetch
RECLAIM_SECS=600

now_s="$(date +%s)"

# init queue files if missing/empty (atomic, 0600)
for f in "$PENDING" "$SEEN"; do
  if [[ ! -s "$f" ]]; then printf '%s' '[]' > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; chmod 600 "$f" 2>/dev/null || true; fi
done

# atomic jq rewrite: jq_write <file> <jq args...>; reads $file, writes tmp+mv
jq_write() {
  local file="$1"; shift
  local tmp="$file.tmp.$$"
  if jq "$@" "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"; chmod 600 "$file" 2>/dev/null || true
  else
    rm -f "$tmp"; return 1
  fi
}

touch_heartbeat() {
  printf '{"ts": %s}' "$(date +%s)" > "$HEARTBEAT.tmp.$$" && mv "$HEARTBEAT.tmp.$$" "$HEARTBEAT"
  chmod 600 "$HEARTBEAT" 2>/dev/null || true
}

state="$(hook_state_get)"
offset="$(printf '%s' "$state" | jq -r '.offset // empty')"

args=(get-updates --timeout 25)
if [[ -n "$offset" ]]; then
  args+=(--offset "$offset")
fi

if ! raw="$(python3 "$HELPER" "${args[@]}" 2>/dev/null)"; then
  log "fetch_failed" '{}'
  silent "telegram fetch failed"
fi

# Fetch succeeded: the poll loop is alive, even if there is nothing new.
touch_heartbeat

count="$(printf '%s' "$raw" | jq -r '.result | length' 2>/dev/null || printf '0')"

if [[ "$count" != "0" ]]; then
messages="$(printf '%s' "$raw" | jq -c '[.result[] | select(.message != null) | {
  update_id: .update_id,
  message_id: .message.message_id,
  chat_id: .message.chat.id,
  message_thread_id: (.message.message_thread_id // null),
  from_id: .message.from.id,
  from_username: (.message.from.username // ""),
  from_first_name: (.message.from.first_name // ""),
  from_is_bot: (.message.from.is_bot // false),
  mentions_bot: (.message as $m | ((($m.text // "") + " " + ($m.caption // "")) | contains("@'"$BOT_USERNAME"'")) or ([($m.entities // [])[] | select(.type == "mention") | ($m.text // "")[.offset:(.offset + .length)]] + [($m.caption_entities // [])[] | select(.type == "mention") | ($m.caption // "")[.offset:(.offset + .length)]] | any(. == "@'"$BOT_USERNAME"'"))),
  reply_to_bot: ((.message.reply_to_message.from.username // "") == "'"$BOT_USERNAME"'"),
  reply_to_message_id: (.message.reply_to_message.message_id // null),
  media_group_id: (.message.media_group_id // ""),
  text: (.message.text // .message.caption // ""),
  caption: (.message.caption // ""),
  has_photo: (.message.photo != null),
  photo_file_id: (if .message.photo then (.message.photo[-1].file_id) else "" end),
  photo_count: (.message.photo // [] | length),
  media_kind: (if .message.photo then "photo" elif .message.voice then "voice" elif .message.document then "document" elif .message.video then "video" elif .message.audio then "audio" elif .message.sticker then "sticker" elif .message.animation then "animation" elif .message.video_note then "video_note" elif (.message.text != null) then "text" elif (.message.new_chat_members != null or .message.left_chat_member != null or .message.new_chat_title != null or .message.pinned_message != null or .message.migrate_from_chat_id != null or .message.migrate_to_chat_id != null or .message.group_chat_created != null or .message.supergroup_chat_created != null or .message.forum_topic_created != null or .message.forum_topic_edited != null or .message.forum_topic_closed != null or .message.forum_topic_reopened != null or .message.video_chat_started != null or .message.video_chat_ended != null or .message.video_chat_participants_invited != null or .message.message_auto_delete_timer_changed != null or .message.chat_owner_left != null or .message.chat_owner_changed != null or .message.proximity_alert_triggered != null) then "service" else "none" end),
  service_kind: (if .message.new_chat_members then "new_chat_members" elif .message.left_chat_member then "left_chat_member" elif .message.new_chat_title then "new_chat_title" elif .message.pinned_message then "pinned_message" elif .message.migrate_from_chat_id then "migrate_from_chat_id" elif .message.migrate_to_chat_id then "migrate_to_chat_id" elif .message.group_chat_created then "group_chat_created" elif .message.supergroup_chat_created then "supergroup_chat_created" elif (.message.forum_topic_created != null or .message.forum_topic_edited != null or .message.forum_topic_closed != null or .message.forum_topic_reopened != null or .message.video_chat_started != null or .message.video_chat_ended != null or .message.video_chat_participants_invited != null or .message.message_auto_delete_timer_changed != null or .message.chat_owner_left != null or .message.chat_owner_changed != null or .message.proximity_alert_triggered != null) then "other" else "" end),
  new_chat_members: ((.message.new_chat_members // []) | map({id: .id, username: (.username // ""), first_name: (.first_name // ""), is_bot: (.is_bot // false)})),
  migrate_from_chat_id: (.message.migrate_from_chat_id // null),
  migrate_to_chat_id: (.message.migrate_to_chat_id // null),
  sticker_file_id: (.message.sticker.file_id // ""),
  sticker_emoji: (.message.sticker.emoji // ""),
  sticker_set_name: (.message.sticker.set_name // ""),
  animation_file_id: (.message.animation.file_id // ""),
  video_note_file_id: (.message.video_note.file_id // ""),
  video_note_duration: (.message.video_note.duration // 0),
  voice_file_id: (.message.voice.file_id // ""),
  voice_duration: (.message.voice.duration // 0),
  document_file_id: (.message.document.file_id // ""),
  document_file_name: (.message.document.file_name // ""),
  document_mime_type: (.message.document.mime_type // ""),
  video_file_id: (.message.video.file_id // ""),
  audio_file_id: (.message.audio.file_id // ""),
  audio_duration: (.message.audio.duration // 0),
  file_name: (.message.document.file_name // .message.audio.file_name // .message.audio.title // "")
}]')"

callbacks="$(printf '%s' "$raw" | jq -c '[.result[] | select(.callback_query != null) | {
  update_id: .update_id,
  callback_id: .callback_query.id,
  from_id: .callback_query.from.id,
  from_username: (.callback_query.from.username // ""),
  from_first_name: (.callback_query.from.first_name // ""),
  chat_id: .callback_query.message.chat.id,
  message_thread_id: (.callback_query.message.message_thread_id // null),
  message_id: .callback_query.message.message_id,
  data: (.callback_query.data // "")
}]')"

# --- dedupe against seen.json (message_id / callback_id) ---
seen_keys="$(jq -r '.[].key' "$SEEN" 2>/dev/null | jq -R . | jq -s -c .)"
new_messages="$(printf '%s' "$messages" | jq -c --argjson seen "$seen_keys" \
  '[.[] | select((("m:" + (.chat_id|tostring) + ":" + (.message_id|tostring)) as $k | ($seen | index($k)) | not)) ]')"
new_callbacks="$(printf '%s' "$callbacks" | jq -c --argjson seen "$seen_keys" \
  '[.[] | select((("cb:" + .callback_id) as $k | ($seen | index($k)) | not)) ]')"
new_msg_keys="$(printf '%s' "$new_messages" | jq -c '[.[] | "m:" + (.chat_id|tostring) + ":" + (.message_id|tostring)]')"
new_cb_keys="$(printf '%s' "$new_callbacks" | jq -c '[.[] | "cb:" + .callback_id]')"
all_new_keys="$(jq -cn --argjson a "$new_msg_keys" --argjson b "$new_cb_keys" '$a + $b')"
if [[ "$(printf '%s' "$all_new_keys" | jq -r 'length')" != "0" ]]; then
  jq_write "$SEEN" --argjson keys "$all_new_keys" --argjson now "$now_s" \
    '. + [$keys[] | {key: ., ts: $now}] | sort_by(.ts) | .[-500:]'
fi

# Receipt fix: answer every NEW callback_query immediately, before waking
# the worker, so the receipt does not expire while the worker starts up.
cb_ids="$(printf '%s' "$new_callbacks" | jq -r '.[].callback_id')"
if [[ -n "$cb_ids" ]]; then
  flags_json=""
  while IFS= read -r cbid; do
    if [[ -z "$cbid" ]]; then
      continue
    fi
    if python3 "$HELPER" answer-callback --callback-query-id "$cbid" >/dev/null 2>&1; then
      flags_json+="true,"
    else
      log "callback_receipt_failed" "$(jq -cn --arg id "$cbid" '{callback_id: $id}')"
      flags_json+="false,"
    fi
  done <<< "$cb_ids"
  if [[ -n "$flags_json" ]]; then
    receipt_flags="[${flags_json%,}]"
    new_callbacks="$(printf '%s' "$new_callbacks" | jq -c --argjson flags "$receipt_flags" '[to_entries[] | .value + {receipt_done: ($flags[.key] // false)}]')"
  fi
fi

# --- land new batch to the durable queue BEFORE advancing the offset ---
if [[ "$(printf '%s' "$new_messages" | jq -r 'length')" != "0" || "$(printf '%s' "$new_callbacks" | jq -r 'length')" != "0" ]]; then
  batch_id="b$(date +%s%N)"
  batch_json="$(jq -cn --arg id "$batch_id" --argjson ts "$now_s" \
    --argjson msgs "$new_messages" --argjson cbs "$new_callbacks" \
    '{batch_id: $id, landed_at: $ts, woken_at: null, status: "queued", messages: $msgs, callbacks: $cbs}')"
  jq_write "$PENDING" --argjson b "$batch_json" '. + [$b]'
fi

# Typing placeholder (owner asked for it 2026-11-17, reversing the 11-09
# veto): light "typing..." in each chat in the new batch as soon as it
# lands, so the owner sees the bot is alive before the worker even starts.
# Best-effort only: never block the wake, never fail the round. Typing
# lasts ~5s server-side; the main session re-lights it when it starts work.
if [[ "$(printf '%s' "$new_messages" | jq -r 'length')" != "0" ]]; then
  for cid in $(printf '%s' "$new_messages" | jq -r '[.[].chat_id] | unique | .[]'); do
    python3 "$HELPER" send-chat-action --chat-id "$cid" --action typing >/dev/null 2>&1 || true
  done
fi

new_offset="$(printf '%s' "$raw" | jq -r '([.result[].update_id] | max) + 1')"
new_state="$(printf '%s' "$state" | jq -c --argjson off "$new_offset" '.offset = $off')"
hook_state_set "$new_state"
fi

# --- reclaim stale inflight batches (>600s without ack) ---
jq_write "$PENDING" --argjson cut "$((now_s - RECLAIM_SECS))" \
  '[.[] | if .status == "inflight" and .woken_at != null and .woken_at < $cut then .status = "queued" | .woken_at = null else . end]'

to_wake="$(jq -c '[.[] | select(.status == "queued")]' "$PENDING")"
if [[ "$(printf '%s' "$to_wake" | jq -r 'length')" == "0" ]]; then
  silent "no new telegram messages"
fi

# --- warm worker owns queued batches while its heartbeat is fresh ---
# A warm worker (bin/warm-wait.sh) claims queued batches itself. If its
# marker heartbeat is fresh (<60s), skip the wake so no duplicate worker
# starts. A stale or missing marker means the warm worker is gone; fall
# through and wake normally. Batches are never lost here: they stay queued
# until acked, and the 600s reclaim still applies to inflight ones.
# (now_s is from the start of this round, up to ~25s stale after the
# long-poll, so a dead worker's marker is honoured for at most ~85s.)
WARM="$QUEUE_DIR/warm.json"
if [[ -s "$WARM" ]]; then
  warm_hb="$(jq -r '.last_heartbeat // 0' "$WARM" 2>/dev/null || printf '0')"
  if [[ "$warm_hb" =~ ^[0-9]+$ ]] && (( now_s - warm_hb < 60 )); then
    log "warm_worker_active" "$(jq -cn --argjson n "$(printf '%s' "$to_wake" | jq -r 'length')" '{queued_batches: $n}')"
    silent "warm worker active"
  fi
fi

wake_messages="$(printf '%s' "$to_wake" | jq -c '[.[].messages[]]')"
wake_callbacks="$(printf '%s' "$to_wake" | jq -c '[.[].callbacks[]]')"
wake_batch_ids="$(printf '%s' "$to_wake" | jq -c '[.[].batch_id]')"
allowlist="$(printf '%s' "$state" | jq -c '.allowlist // []')"
payload="$(jq -cn --argjson messages "$wake_messages" --argjson callbacks "$wake_callbacks" \
  --argjson allowlist "$allowlist" --argjson batch_ids "$wake_batch_ids" \
  '{messages: $messages, callbacks: $callbacks, allowlist: $allowlist, batch_ids: $batch_ids}')"
log "messages_received" "$(jq -cn --argjson n "$(printf '%s' "$wake_messages" | jq -r 'length')" \
  --argjson c "$(printf '%s' "$wake_callbacks" | jq -r 'length')" '{count: $n, callbacks: $c}')"

# Mark inflight BEFORE wake: wake() exits the process on success, so
# nothing after it runs. If wake fails to emit, revert to queued.
jq_write "$PENDING" --argjson ids "$wake_batch_ids" --argjson now "$now_s" \
  '[.[] | if (.batch_id as $b | ($ids | index($b)) != null) then .status = "inflight" | .woken_at = $now else . end]'
if wake "telegram messages received" "$payload"; then
  : # unreachable on success: wake() exits 0 inside _hatch_hook_emit
else
  log "wake_failed" "$(jq -cn --argjson ids "$wake_batch_ids" '{batch_ids: $ids}')"
  jq_write "$PENDING" --argjson ids "$wake_batch_ids" \
    '[.[] | if (.batch_id as $b | ($ids | index($b)) != null) then .status = "queued" | .woken_at = null else . end]'
fi
