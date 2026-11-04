#!/usr/bin/env python3
"""Search Telegram bridge conversation history by keyword.

Searches the per-chat state files under ~/workspace/telegram-bridge/state/
and the archived session snapshots under
~/workspace/telegram-bridge/archive/<chat_id>/<session_id>.json,
matching the keyword (case-insensitive substring) against each file's
summary and every recent_turns entry.

Usage:
    search-history.py <keyword> [--root <telegram-bridge dir>]

Each hit is printed as one line:
    [chat <id> topic <thread_id|->] session <session_id> | <when> | <text>
"""
import argparse
import glob
import json
import os
import re
import sys

DEFAULT_ROOT = os.path.expanduser("~/workspace/telegram-bridge")


def parse_state_filename(name):
    """'123.json' -> (123, None); '123-t45.json' -> (123, 45)."""
    m = re.match(r"^(\d+)(?:-t(\d+))?\.json$", name)
    if not m:
        return None, None
    return int(m.group(1)), (int(m.group(2)) if m.group(2) else None)


def turn_texts(turn):
    """Yield (when, text) pairs from one recent_turns entry."""
    if isinstance(turn, str):
        yield "", turn
        return
    if not isinstance(turn, dict):
        return
    when = turn.get("ts") or turn.get("time") or ""
    for key in ("user", "assistant", "text"):
        val = turn.get(key)
        if isinstance(val, str) and val:
            yield when, val


def search_file(path, keyword, label_chat, label_topic):
    hits = []
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warn: cannot read {path}: {exc}", file=sys.stderr)
        return hits
    if not isinstance(data, dict):
        return hits
    chat = data.get("chat_id", label_chat)
    topic = data.get("message_thread_id", label_topic)
    session = (
        data.get("session_id")
        or data.get("current_session_id")
        or "?"
    )
    kw = keyword.lower()
    summary = data.get("summary") or ""
    if isinstance(summary, str) and kw in summary.lower():
        hits.append((chat, topic, session, "summary", summary.strip()))
    for turn in data.get("recent_turns") or []:
        for when, text in turn_texts(turn):
            if kw in text.lower():
                hits.append((chat, topic, session, when, text.strip()))
    return hits


def main():
    parser = argparse.ArgumentParser(description="Search Telegram bridge history")
    parser.add_argument("keyword")
    parser.add_argument("--root", default=DEFAULT_ROOT)
    args = parser.parse_args()
    root = os.path.expanduser(args.root)

    all_hits = []
    for path in sorted(glob.glob(os.path.join(root, "state", "*.json"))):
        chat, topic = parse_state_filename(os.path.basename(path))
        all_hits += search_file(path, args.keyword, chat, topic)
    for path in sorted(glob.glob(os.path.join(root, "archive", "*", "*.json"))):
        chat_dir = os.path.basename(os.path.dirname(path))
        chat = int(chat_dir) if chat_dir.isdigit() else None
        all_hits += search_file(path, args.keyword, chat, None)

    for chat, topic, session, when, text in all_hits:
        topic_s = topic if topic is not None else "-"
        snippet = " ".join(text.split())
        if len(snippet) > 200:
            snippet = snippet[:200] + "…"
        print(
            f"[chat {chat} topic {topic_s}] session {session} | "
            f"{when or '-'} | {snippet}"
        )
    print(f"# {len(all_hits)} hit(s) for {args.keyword!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
