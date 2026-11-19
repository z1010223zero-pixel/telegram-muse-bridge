#!/usr/bin/env python3
"""Per-chat state bookkeeping for the Telegram bridge (worker-side).

Usage:
  record-state.py --check --chat-id <id> --message-id <id>
      Exit 0 if m:<chat_id>:<message_id> is already in handled_message_ids,
      exit 1 if not.
  record-state.py --record --chat-id <id> --message-id <id> --role user|assistant
      --text <text> [--from-id <id>] [--from-first-name <name>]
      [--reply-message-id <id>]
      Append the handled key (deduped, last 50 kept) and a recent_turns
      entry (last 100 kept). Creates the state file with a minimal schema
      if it does not exist yet.

State files live in $HOME/workspace/telegram-bridge/state/<chat_id>.json
(0700 dir, 0600 files, atomic tmp+rename writes). --state-dir overrides
the directory (used by the harness).
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

CST = timezone(timedelta(hours=8))


def state_path(state_dir, chat_id):
    return os.path.join(state_dir, "%s.json" % chat_id)


def load(state_dir, chat_id):
    path = state_path(state_dir, chat_id)
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def save(state_dir, chat_id, data):
    os.makedirs(state_dir, exist_ok=True)
    try:
        os.chmod(state_dir, 0o700)
    except OSError:
        pass
    path = state_path(state_dir, chat_id)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def new_state(chat_id):
    now = datetime.now(CST).isoformat(timespec="seconds")
    return {
        "album_buffer": [],
        "approvals": [],
        "chat_id": int(chat_id),
        "chat_title": "",
        "chat_type": "private",
        "last_error_reply_at": None,
        "recent_turns": [],
        "session_id": now[:10] + "-tg",
        "session_started_at": now,
        "summary": "",
        "todos": [],
        "handled_message_ids": [],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--chat-id", required=True)
    ap.add_argument("--message-id", required=True)
    ap.add_argument("--role", choices=["user", "assistant"])
    ap.add_argument("--text", default="")
    ap.add_argument("--from-id", default="")
    ap.add_argument("--from-first-name", default="")
    ap.add_argument("--reply-message-id", default="")
    ap.add_argument("--state-dir", default=None)
    args = ap.parse_args()

    state_dir = args.state_dir or os.path.join(
        os.environ.get("HOME", "/home/hatch"),
        "workspace", "telegram-bridge", "state",
    )
    key = "m:%s:%s" % (args.chat_id, args.message_id)

    if args.check:
        data = load(state_dir, args.chat_id)
        handled = (data or {}).get("handled_message_ids", []) or []
        return 0 if key in handled else 1

    if args.record:
        if args.role is None:
            ap.error("--record requires --role")
        data = load(state_dir, args.chat_id) or new_state(args.chat_id)
        handled = data.get("handled_message_ids", []) or []
        if key not in handled:
            handled.append(key)
        data["handled_message_ids"] = handled[-50:]
        entry = {
            "at": datetime.now(CST).isoformat(timespec="seconds"),
            "message_id": int(args.reply_message_id)
            if args.reply_message_id
            else int(args.message_id),
            "role": args.role,
            "text": args.text,
        }
        if args.role == "user":
            if args.from_id:
                entry["from_id"] = int(args.from_id)
            if args.from_first_name:
                entry["from_first_name"] = args.from_first_name
        turns = data.get("recent_turns", []) or []
        turns.append(entry)
        data["recent_turns"] = turns[-100:]
        save(state_dir, args.chat_id, data)
        print(json.dumps({"handled": key, "turns": len(data["recent_turns"])}))
        return 0

    ap.error("specify --check or --record")
    return 2


if __name__ == "__main__":
    sys.exit(main())
