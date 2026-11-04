#!/usr/bin/env bash
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

HELPER="$HOME/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py"

# 模板说明：把本文件改名为 telegram-bridge.sh 放到 ~/hooks/scripts/ 下使用。
# 文件里三处 YOUR_BOT_USERNAME（@ 判断与 reply_to_bot 判断）须替换成你自己 Bot 的用户名。

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

count="$(printf '%s' "$raw" | jq -r '.result | length' 2>/dev/null || printf '0')"
if [[ "$count" == "0" ]]; then
  silent "no new telegram messages"
fi

messages="$(printf '%s' "$raw" | jq -c '[.result[] | select(.message != null) | {
  update_id: .update_id,
  message_id: .message.message_id,
  chat_id: .message.chat.id,
  message_thread_id: (.message.message_thread_id // null),
  from_id: .message.from.id,
  from_username: (.message.from.username // ""),
  from_first_name: (.message.from.first_name // ""),
  from_is_bot: (.message.from.is_bot // false),
  mentions_bot: (.message as $m | ((($m.text // "") + " " + ($m.caption // "")) | contains("@YOUR_BOT_USERNAME")) or ([($m.entities // [])[] | select(.type == "mention") | ($m.text // "")[.offset:(.offset + .length)]] + [($m.caption_entities // [])[] | select(.type == "mention") | ($m.caption // "")[.offset:(.offset + .length)]] | any(. == "@YOUR_BOT_USERNAME"))),
  reply_to_bot: ((.message.reply_to_message.from.username // "") == "YOUR_BOT_USERNAME"),
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

# Receipt fix: answer every callback_query immediately, before waking the
# worker, so the receipt does not expire while the worker starts up.
# receipt_done is set per callback (same order as the callbacks array);
# a failed receipt leaves receipt_done=false and the worker falls back to
# answering it itself. Receipt failures are logged, never fatal.
cb_ids="$(printf '%s' "$raw" | jq -r '.result[] | select(.callback_query != null) | .callback_query.id')"
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
    callbacks="$(printf '%s' "$callbacks" | jq -c --argjson flags "$receipt_flags" '[to_entries[] | .value + {receipt_done: ($flags[.key] // false)}]')"
  fi
fi

new_offset="$(printf '%s' "$raw" | jq -r '([.result[].update_id] | max) + 1')"

new_state="$(printf '%s' "$state" | jq -c --argjson off "$new_offset" '.offset = $off')"
hook_state_set "$new_state"

msg_count="$(printf '%s' "$messages" | jq -r 'length')"
cb_count="$(printf '%s' "$callbacks" | jq -r 'length')"
if [[ "$msg_count" == "0" && "$cb_count" == "0" ]]; then
  silent "only non-message telegram updates"
fi

allowlist="$(printf '%s' "$state" | jq -c '.allowlist // []')"
payload="$(jq -cn --argjson messages "$messages" --argjson callbacks "$callbacks" --argjson allowlist "$allowlist" '{messages: $messages, callbacks: $callbacks, allowlist: $allowlist}')"
log "messages_received" "$(jq -cn --argjson n "$msg_count" --argjson c "$cb_count" '{count: $n, callbacks: $c}')"
wake "telegram messages received" "$payload"
