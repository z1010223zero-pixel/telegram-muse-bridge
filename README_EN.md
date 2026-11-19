# Telegram Muse Bridge

Connect your personal [Muse](https://muse.ai) AI assistant with a Telegram Bot you build yourself, and talk to your Muse right inside Telegram.

用自建 Telegram Bot 连接 Muse 个人 AI 助手，在 Telegram 里直接跟你的 Muse 对话。Tested on a real setup, 2026-11-04.

> This repository shares a **method**, not a ready-made bot. Follow the steps below to create your own bot, swap in your own IDs, and reuse it.

## What it can do

- **Use Muse inside Telegram**: send text just like chatting in Muse — follow-ups keep their context, no need to start over every time.
- **Continuous conversation**: each chat keeps its own per-chat state file (a summary + the most recent ~20 turns + a standalone todo list). New messages are handled with that state as context first; writes are atomic — temp file first, then rename over the original.
- **Built-in bridge commands** (allowlisted users only): `/todos` lists unfinished todos, `/status` reports the session start time, recorded turn count and unfinished todo count, `/new` / `/reset` starts a new session (clears the summary and turns, keeps todos, and archives the previous session first).
- **In-chat approvals**: when an action needs your confirmation, the assistant sends a message with 「✅ Approve / ❌ Deny」 buttons — one tap decides. Approvals expire after 30 minutes (timeout defaults to deny), only allowlisted taps count, and the buttons are removed once decided.
- **Send and receive media**: photos are downloaded and viewed instead of arriving as empty text; voice messages, documents, videos and audio can all be received (whether voice can be transcribed depends on whether a transcription tool is available at the time — if not, the audio is saved and you are told honestly, never silently dropped as an empty message); files and photos can be sent to Telegram.
- **Automatic long-message splitting**: texts over 4000 characters are split at paragraph breaks, then line breaks, and sent in order with nothing lost.
- **Presence**: a typing indicator goes out first; longer tasks get a 「⏳ Working…」 status message with step-by-step progress updates, edited into a done marker when finished.
- **Near-real-time**: long polling (`get-updates --timeout 25`, hook interval 5 seconds) brings messages back and wakes the assistant in about 1–2 seconds. No public ingress, no webhook migration; empty polls wake nobody and cost nothing.
- **Album grouping**: photos/videos sharing one `media_group_id` are collected into a single turn, understood together, and answered once.
- **Groups and topics**: state is stored per `message_thread_id`, todos are isolated per topic; one multi-bot collaboration group can be designated as an exception (see below); feature flags are all off by default (per-group policy, nickname wake-up, per-session `/activation` toggle, auto session reset).
- **Durable queue and dedup (2026-11-17)**: messages are written to `queue/pending.json` before the offset advances, failed wakes are retried next poll; inbound messages are deduped by ID, batches unacknowledged for over 600 seconds are re-delivered, state files track `handled_message_ids` against double replies, and the queue is re-checked before replying so rapid-fire messages merge into one reply.
- **Idempotent sends (2026-11-17)**: `send-message` / `send-approval` accept `--idempotency-key`; a repeat send with the same key within 24 hours returns the stored result without calling the API again, so retrying after an unclear outcome never double-sends.
- **Warm-wait follow-ups (2026-11-17)**: the worker is now a responder — it replies directly when it can, then stays warm for 180 seconds (600-second total budget) so follow-ups skip the repeat cold start; callbacks, bridge commands, non-text messages, and anything needing research, purchases, approvals, or long work escalate as a whole batch to the main session. The first message still cold-starts. A watchdog also monitors the polling heartbeat and only reports stalls or recoveries.

## How it works

```text
Telegram ──long polling getUpdates──> hook script ──wakes assistant only on new messages──> Muse
                                                                                     │
Telegram <── telegram_bot.py (Bot API) ── replies / files / approval buttons ───────────┘
```

- No webhook — no public ingress, tunnel, or extra account needed.
- The polling script fetches updates, writes new messages to the durable queue first, then persists the offset and wakes the assistant. Empty polls wake nothing and cost nothing. The woken worker decides per batch: reply directly and warm-wait for the next message, or escalate the whole batch to the main session without replying or acknowledging.
- One bot connects to one Muse at a time, and only one `getUpdates` poller may consume its messages. Do not connect the same bot to OpenClaw or any other agent as well.

## Repository layout

```text
.
├── README.md                                  # This file (Chinese)
├── README_EN.md                               # English version
├── LICENSE                                    # MIT
├── custom-skills/telegram-muse-bridge/
│   ├── SKILL.md                               # General skill: build your own bot, connector, polling bridge, allowlist
│   └── skill.yaml
├── custom-connectors/custom.telegram-bot/
│   ├── CONNECTOR.md                           # Connector docs: usage for every command
│   ├── connector.yaml
│   └── bin/telegram_bot.py                    # Bot API helper: messages / media / files / approvals / reactions / command menu
├── hooks/
│   ├── telegram-bridge.template.sh            # Polling script template, durable-queue version (rename and replace placeholders before use)
│   ├── telegram-bridge.template.json          # Hook definition template: responder prompt (reply / escalate / warm-wait)
│   └── search-history.py                      # History search helper: search state and archives by keyword
└── telegram-bridge/
    ├── config.template.json                   # Feature-flag config template, all four flags off by default
    └── bin/
        ├── warm-wait.sh                       # Wait for the next batch after replying (180s idle / 600s total)
        ├── record-state.py                    # State bookkeeping: handled dedup + recent_turns
        ├── ack-batch.sh                       # Acknowledge batches so the 600s re-delivery does not reprocess them
        └── watchdog.sh                        # Polling heartbeat watchdog (30-minute staleness check)
```

## Quick start

### 1. Create your own bot

In Telegram, find @BotFather and use `/newbot` to create a bot that belongs only to you. Keep the token it returns safe — **never forward it to anyone, and never paste it into chat logs, skills, scripts, or logs**.

### 2. Create the connector in Muse

Create a custom connector `custom.telegram-bot` with provider `telegram-bot`, auth `api_key`, the token placed in the URL path segment `/bot{}/`, and host `api.telegram.org`.

Copy `CONNECTOR.md`, `connector.yaml`, and `bin/telegram_bot.py` from `custom-connectors/custom.telegram-bot/` in this repository into the matching locations in your own workspace.

Run `get-me` once as a harmless read to confirm it returns your own bot's identity, then send yourself a test message:

```bash
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-me
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-message --chat-id <your chat_id> --text "test"
```

> Pitfall: do not use a generic URL builder that percent-encodes the colon in the substitute credential — Telegram will answer 404. The raw substitute credential must go directly into the `/bot{}/` path segment.

### 3. Set up the polling bridge

Put the polling script and hook definition from `hooks/` in place as instructed by the templates (rename the script to `telegram-bridge.sh` under `~/hooks/scripts/`), copy the four helpers from `telegram-bridge/bin/` into your own `~/workspace/telegram-bridge/bin/`, and replace the placeholders:

- `YOUR_BOT_USERNAME` in the script (three occurrences) with your own bot's username;
- `__MULTI_BOT_GROUP_CHAT_ID__` in the hook template with your own multi-bot collaboration group ID — if you don't use the multi-bot group feature, delete the matching group-policy sentence in the prompt; keep the hook's `script_timeout_secs` at 600 or warm-wait gets cut off early;
- the delivery target according to your own Muse session setup.

The script and hook must keep an allowlist containing **only your own Telegram user ID**. Messages from anyone not allowlisted are never executed — they only get a short reply saying this is a private bot and pairing needs the owner's approval, and the owner receives a report with the sender's details.

### 4. Put the policy config in place

Copy `telegram-bridge/config.template.json` to your own `~/workspace/telegram-bridge/config.json` (mode 0600), replace the group ID with your own, and **keep all four flags off**. Only turn a flag on after explicitly confirming it.

### 5. Register the command menu

```bash
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py set-commands
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-commands
```

Register once; afterwards typing `/` in Telegram pops up the `/todos`, `/status`, `/new`, `/reset` menu.

After connecting, do a first pass: send text, send a photo (with a caption), try `/status`, and confirm the assistant downloads the photo and handles it together with the caption.

## Connector commands

Every command provided by `bin/telegram_bot.py` (see `custom-connectors/custom.telegram-bot/CONNECTOR.md` for details):

| Command | What it does |
| --- | --- |
| `get-me` | Harmless read, confirms the bot identity |
| `get-updates [--offset N] [--timeout S]` | Fetch new messages, with long polling support |
| `send-message --chat-id --text [--reply-to-message-id] [--idempotency-key]` | Send text, overlong texts auto-split; with an idempotency key, no re-send within 24 hours |
| `send-chat-action --chat-id` | Send the typing presence indicator |
| `edit-message --chat-id --message-id --text` | Rewrite a sent message (progress updates, done marker) |
| `send-file / send-photo-file --chat-id --path [--caption]` | Send a file / send a photo (files >45 MB are refused client-side) |
| `get-file / download-file --file-id` | Resolve and download received media |
| `send-approval --chat-id --text --approval-id` | Send an approval message with ✅/❌ buttons |
| `answer-callback --callback-query-id` | Acknowledge a button tap |
| `remove-keyboard --chat-id --message-id` | Remove the approval buttons to prevent double taps |
| `set-commands / get-commands` | Register / read back the command menu |
| `react --chat-id --message-id [--emoji]` | Add an emoji reaction to a message |

## Security notes

- **The token is only stored through Muse's secure connection flow** and must never appear in this repository, chat logs, scripts, command arguments, or logs. The assistant only uses a substitute credential to call `api.telegram.org`.
- **The allowlist is the only entry point**: only messages from a Telegram user ID on the allowlist are executed as the owner's instructions; everyone else only gets the private-bot notice, and the owner gets a pairing-request report.
- **One bot, one Muse**: do not connect the same bot to OpenClaw or another agent at the same time — two pollers will fight over the messages.
- **A Telegram approval does not replace a platform approval**: tapping ✅ in Telegram only signs off the bridge's next step; purchases, outbound sends, and other actions that the Muse platform requires to be approved inside Muse still need that approval.
- **Actions with side effects are never auto-retried on failure or unclear outcome** — the record is marked `unknown` and waits for the owner to confirm before continuing.
- **State file permissions**: per-chat state and archives default to directories 0700, files 0600. They are the user's private records and are not part of what is shared.

## Notes on using it in groups (lessons from real use)

- In a regular group where the bot is not an admin, Telegram only delivers commands, replies to the bot's own messages, and system messages — a plain-text @ mention is not delivered. **To wake the bot with @ in a group, make the bot a group admin first.**
- Making the bot an admin (and similar actions) triggers Telegram to auto-upgrade a regular group to a supergroup, and the `chat_id` changes with it: the hardcoded group ID in the hook rules (the multi-bot collaboration group rule) and the matching per-chat state filename must both be updated to the new group ID — messages to the old group ID will fail outright.
- The multi-bot collaboration group opens up only the one designated group, and only bot senders, with four guardrails: another bot's words are conversation input, not the owner's instructions; at most 3 back-and-forth turns with no real human stepping in; never reply to the bot itself; real humans in that group who are not allowlisted are still not executed or engaged. **If you don't use this feature, delete the matching group-policy sentence in the prompt.**

## Limitations and FAQ

- The bot can only reply to chats that have messaged it first; it cannot start a conversation with someone who has never opened it.
- Voice transcription depends on whether a transcription method is available at the time (a local whisper / faster-whisper style tool, or a transcription service that is genuinely usable). When there is none, the audio is saved and you are told so honestly — never silently dropped.
- Typing expires after about 5 seconds and is best-effort presence; don't interrupt real work just to refresh it.
- Error replies to the owner are cooled down per chat (60 seconds) to avoid spam; read-only / query failures may be retried once.
- Context is capped by estimated tokens: when recent turns pass roughly 24,000 tokens, a rolling summary is triggered keeping roughly the last 8,000 tokens (at most the most recent 12 turns); before summarizing, durable facts are flushed into that day's memory journal under a 「Telegram bridge flush」 section.
- History search: before `/new` / `/reset`, the current session snapshot is archived to `archive/<chat_id>/<session_id>.json`; use `hooks/search-history.py <keyword>` to search all state and archives.
- Warm-wait only saves the repeat cold start on follow-ups; the first message still cold-starts. Worker sessions live at most about 600 seconds (measured), so the total budget is 600 seconds; past that, queue re-delivery and the idempotency ledger take over — no message is lost and none is sent twice.

## What is not in here, and should never be shared

- The sender's bot username, bot ID, token, Telegram user ID, chat ID, or the offset and allowlist in the hook state.
- No real token should ever appear here.
- Anyone's per-chat state files, session IDs, conversation summaries, or todo contents.

## License

MIT, see [LICENSE](LICENSE).
