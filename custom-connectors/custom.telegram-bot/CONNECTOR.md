# Telegram Bot

- `custom.telegram-bot` connects Muse to the Telegram Bot API at `api.telegram.org`. It authenticates with the registered `api_key` credential, which Telegram reads as the token in the `/bot<token>/` URL path segment.

- The helper is `~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py`. It provides `get-me`, `get-updates`, `send-message`, `send-chat-action`, `edit-message`, `send-file`, `send-photo-file`, `get-file`, `download-file`, `send-approval`, `answer-callback`, `remove-keyboard`, `set-commands`, `get-commands` and `react`.

- The Telegram bridge hook at `~/hooks/scripts/telegram-bridge.sh` polls this command with long polling (`get-updates --timeout 25`, hook interval 5 seconds). It stores its offset and the approved sender allowlist in its hook state. Polling is done by the script alone and wakes an agent only when a message arrives.

## Receive photos and other media

- Run `get-file` to resolve a media `file_id` to its Telegram `file_path`, then `download-file` to save it locally:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-file --file-id <file_id>
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py download-file --file-id <file_id> --out <local_path>
```

- The bridge script classifies every incoming message with a `media_kind` field (`photo` / `voice` / `document` / `video` / `audio` / `sticker` / `animation` / `video_note` / `text` / `service` / `none`) and passes the matching file id: `photo_file_id` (largest size, plus `has_photo` and `photo_count`), `voice_file_id` (with `voice_duration`), `document_file_id` (with `document_file_name` and `document_mime_type`), `video_file_id`, `audio_file_id` (with `audio_duration`), `sticker_file_id` (with `sticker_emoji` and `sticker_set_name`), `animation_file_id`, and `video_note_file_id` (with `video_note_duration`); `file_name` carries the document or audio file name when present. It also passes `message_id`, `media_group_id`, `reply_to_message_id`, and for service messages a `service_kind` with the new-member list and any chat-migration ids. The caption is passed as `text`. So a photo — and likewise a voice message, document, video or audio file — can be downloaded and handled instead of arriving as an empty message. The helper itself does not transcribe voice; whether a downloaded voice message can be transcribed depends on tooling available to the handling agent at that moment.

- The connected bot is your own bot, created by you via @BotFather. Replace this line with your own bot's display name and username after `getMe` verifies it. Never reuse someone else's bot: one bot connects to only one Muse, and only one `getUpdates` poller can consume its updates.

## Connect

- The connection was registered with `credentials.request_api_access` and these details. Reuse them to reconnect:

```json
{
  "provider": "telegram-bot",
  "auth_scheme": "api_key",
  "placement": "url_path_segment:/bot{}",
  "api_hosts": ["api.telegram.org"]
}
```

- Before the first change in a conversation, prove access with a harmless read:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-me
```

## Credentials

- The registered connection holds the credential. Helpers import `/opt/muse/skills/custom-connector-setup/bin/dynamic_credentials.py`, which returns an `hsurr:` surrogate. Muse swaps in the real credential only on an approved request to a registered host.

- Never put a key, token, password or cookie in this doc, a helper, a command argument, an environment variable or a log. Never ask the user to paste one in chat.

- Keep redirects disabled on authenticated requests.

- On a 401 or 403, check the request first. Confirm that the helper attached the credential, that the host is registered and that the placement and scopes match.

- Only when a request that carried the credential is still rejected, call `credentials.request_api_access` with the details above and `"reconnect": true`.

## Read the bot identity

- Run `get-me` to read the bot account this credential controls. It changes nothing:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-me
```

- The output is the Telegram `getMe` JSON. Read `result.id`, `result.username` and `result.first_name` from it.

## Read new messages

- Run `get-updates` to read message updates the bot has received. Pass `--offset <update_id>` to confirm all earlier updates and read only newer ones. Pass `--timeout <seconds>` for Telegram long polling, with 0 for an immediate return:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-updates --offset 123456789
```

- The output is the Telegram `getUpdates` JSON. Each entry in `result` carries `update_id` and, for text messages, `message.chat.id`, `message.from.id` and `message.text`. The helper requests `allowed_updates` of `["message", "callback_query"]`, so button clicks on approval messages also arrive, as entries with a `callback_query` object (`id`, `from.id`, `message.message_id`, `data`).

- The Telegram bridge hook at `~/hooks/scripts/telegram-bridge.sh` polls this command with long polling (`get-updates --timeout 25`, hook interval 5 seconds). It stores its offset and the approved sender allowlist in its hook state. Polling is done by the script alone and wakes an agent only when a message arrives.

## Send a message

- Run `send-message` to send one text message from the bot to a chat. Verify it by sending a test message to your own chat first:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-message --chat-id <chat_id> --text <text>
```

- The output is the Telegram `sendMessage` JSON with the sent message in `result`.
- Long texts are split automatically: Telegram rejects texts over 4096 characters, so `send-message` splits anything over 4000 characters into ordered chunks (preferring paragraph breaks, then line breaks, then a hard cut; no content is lost) and sends them one by one. In that case the output is a summary JSON, `{"ok": true, "chunks": <n>, "message_ids": [<ids in order>]}`. Texts within the limit keep the original single-send behaviour and output.

## Bot command menu （命令菜单）

- `set-commands` registers the bot's command menu with Telegram (`setMyCommands`): `todos`（查看未完成待办）, `status`（查看当前会话状态）, `new`（开启新会话）, `reset`（重置当前会话）. After running it once, the menu appears when the owner types `/` in the chat. Register once, then verify with `get-commands`:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py set-commands
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-commands
```

- `get-commands` is a harmless read (`getMyCommands`) that returns the currently registered menu.

## Proactive pushes （主动推送）

- Convention: any Muse context that learns something genuinely important or time-sensitive for the owner (a deadline, a significant change, something they are waiting on) MAY push it to them directly on Telegram with `send-message` to the owner's chat (fill in your own chat id), without waiting for them to message first. Restraint is part of the convention: push only important / time-sensitive items; routine progress and ordinary updates do NOT get pushed.
- After pushing, record it: append the pushed text to the main per-chat state file `~/workspace/telegram-bridge/state/<owner_chat_id>.json` in `recent_turns` as an entry with `role: "assistant"` and `proactive: true` (plus the message text and returned `message_id`), using an atomic write (temp file + rename, keep mode 0600), so later bridge turns can see that he was already told.
- The bot can only push to chats that have messaged it before; The owner's chat qualifies (they have messaged the bot before). Verify the channel once with a short test push and note its message_id in your own records.

## Presence (在场感)

- `send-chat-action` shows a "typing…" indicator in the chat (`sendChatAction`); the indicator fades after about 5 seconds, so it is best-effort presence, not a progress bar:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-chat-action --chat-id <chat_id> [--action typing]
```

- `edit-message` rewrites a message the bot already sent (`editMessageText`), e.g. turning a "⏳ 处理中…" status message into a done marker. The new text must be within the 4000-character limit; the helper refuses longer texts (send a new message instead):

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py edit-message --chat-id <chat_id> --message-id <message_id> --text <text>
```

## Send files (发文件)

- `send-file` uploads a local file to a chat as a document (`sendDocument`, multipart/form-data). The helper refuses files that do not exist or are over 45 MB:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-file --chat-id <chat_id> --path <local_path> [--caption <caption>]
```

- `send-photo-file` does the same via `sendPhoto`, for image files that should render as photos in the chat:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-photo-file --chat-id <chat_id> --path <local_path> [--caption <caption>]
```

## Approvals in chat (审核)

Three commands implement an in-chat approval loop:

- `send-approval` starts an approval: it sends a message with one inline-keyboard row holding two buttons, ✅ 同意 (`callback_data` = `approve:<approval-id>`) and ❌ 拒绝 (`callback_data` = `deny:<approval-id>`). Keep approval ids short: Telegram limits `callback_data` to 64 bytes.

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-approval --chat-id <chat_id> --text <text> --approval-id <approval-id>
```

- The user's click comes back through `get-updates` as a `callback_query` update. The bridge script extracts it into the wake payload's `callbacks` array.
- `answer-callback` acknowledges the click (Telegram stops the button's loading spinner; an optional `--text` shows a short note to the clicker):

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py answer-callback --callback-query-id <callback_query_id> [--text <text>]
```

- `remove-keyboard` removes the buttons from the original approval message so it cannot be clicked twice:

```text
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py remove-keyboard --chat-id <chat_id> --message-id <message_id>
```

The full loop is: `send-approval` → user taps a button → `callback_query` arrives via `get-updates` → `answer-callback` → `remove-keyboard` → the recorded decision is acted on (or not). The bridge polling script answers each callback immediately itself, before waking the worker (callbacks carry `receipt_done: true` in the wake payload; the worker then skips its own `answer-callback` and only falls back to answering when `receipt_done` is false), because a worker that starts up first would answer too late and Telegram would reject the receipt as expired. Approval records, allowlist checks, expiry and default-deny live in the bridge's per-chat state and wake rules, not in this connector. A Telegram approval is the owner's sign-off for the bridge's own next step; it does not replace any approval the Muse platform itself requires inside Muse.

## OpenClaw parity batches （对标补齐）

Three batches bring the bridge close to OpenClaw's Telegram plugin behaviour:

- **Long polling （长轮询）**: `get-updates` accepts `--timeout <seconds>` (default 0, passed through to Telegram's `timeout`). The bridge script polls with `--timeout 25` and the hook interval is 5s; polls are serial, so idle rounds hold ~25s and the next starts immediately — effectively a persistent long connection, with wake latency of ~1-2s instead of up to 15s. Keep the helper's HTTP timeout (35s) above the long-poll timeout.

- **Message surface （消息面）**: `send-message`, `send-file`, `send-photo-file` and `send-approval` accept `--reply-to-message-id <id>` to quote a triggering message (the bridge uses this in groups only). New `react` command wraps `setMessageReaction`:

  ```text
  python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py react --chat-id <chat_id> --message-id <message_id> [--emoji 👀]
  ```

  The polling script additionally extracts `message_id`, `media_group_id` (album grouping via an `album_buffer` in per-chat state), `reply_to_message_id`, sticker / animation / video_note media, and service messages (`media_kind: "service"` with `service_kind` and the new-member list). Service messages are recorded silently by the bridge instead of triggering "no readable text" clarifications.

- **Feature flags （策略开关，默认全关）**: `~/workspace/telegram-bridge/config.json` (0600) holds `features` (`per_group_policy`, `mention_patterns`, `activation_toggle`, `auto_reset` — all `false` by default), per-group `groups` settings (`require_mention`, `allow_from`), `mention_patterns`, and `auto_reset` (`daily_at`, `idle_hours`). The bridge's wake rules read it before handling each message; with every flag off, behaviour is exactly as before. Only flip a flag to `true` on the owner's explicit, confirmed request.

## Recover from errors

- A 404 from Telegram on `getMe` means Telegram did not accept the token in the request. First check that the helper placed the surrogate in the `/bot{}/` segment without percent-encoding it. The bundled `url_with_surrogate_path_segment` helper percent-encodes the surrogate colon, the egress swap then does not match, and Telegram returns 404 even for a valid token. The helper in this connector places the raw surrogate instead, which was verified to return 200.

- After a failed or timed-out change, check the current state with a read before trying again, because the first request may have completed.

## Limits

- Only one poller can consume a bot's updates. Do not run a second `getUpdates` consumer for this bot, and do not connect this same bot to another agent such as OpenClaw.

- The bot can only message chats that have messaged it first. It cannot start a conversation with a user who has never opened it.

## Related skills

- Use `muse.skill_search` to find other skills and `muse.connector_search` to find other connectors.
