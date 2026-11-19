#!/usr/bin/env python3
"""Telegram Bot API helper for the custom.telegram-bot connector.

The bot token never appears here. It is fetched as an hsurr: surrogate
from dynamic_credentials and placed into the /bot{}/ path segment, and
Muse swaps in the real token only on egress to api.telegram.org.
"""
import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import dynamic_credential_entry, read_json_response

CREDENTIAL = "custom.telegram-bot"
ALLOWED_HOSTS = ["api.telegram.org"]
BASE = "https://api.telegram.org/bot{}/"

# Telegram rejects message texts longer than 4096 characters; keep a safety
# margin and split at 4000. Bots may upload files up to 50 MB via sendDocument;
# refuse anything over 45 MB client-side.
TEXT_LIMIT = 4000
MAX_UPLOAD_BYTES = 45 * 1024 * 1024

# Idempotent sends (ilink retrofit, 2026-11-17): a local ledger of
# (chat_id, idempotency_key) -> sent message_ids. A repeat send with the
# same key within 24h returns the stored result without calling the API,
# so a retry after an ambiguous failure never double-sends. The key is
# caller-chosen; the bridge passes the source Telegram message_id.
# Ledger lives outside the workspace so a workspace reset cannot wipe it;
# override with TELEGRAM_SEND_LEDGER. File is 0600.
LEDGER_PATH = os.environ.get(
    "TELEGRAM_SEND_LEDGER",
    os.path.expanduser("~/.cache/telegram-send-ledger.json"),
)
LEDGER_TTL_SECS = 24 * 3600
LEDGER_MAX_ENTRIES = 200


def _ledger_load():
    try:
        with open(LEDGER_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict) and isinstance(data.get("entries"), list):
            return data["entries"]
    except (OSError, ValueError):
        pass
    return []


def _ledger_save(entries):
    directory = os.path.dirname(LEDGER_PATH)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = LEDGER_PATH + ".tmp." + str(os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"entries": entries}, fh, ensure_ascii=False)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, LEDGER_PATH)
    try:
        os.chmod(LEDGER_PATH, 0o600)
    except OSError:
        pass


def _ledger_lookup(chat_id, key):
    now = time.time()
    for entry in _ledger_load():
        if entry.get("chat_id") == str(chat_id) and entry.get("key") == key:
            if now - entry.get("ts", 0) <= LEDGER_TTL_SECS:
                return entry
    return None


def _ledger_record(chat_id, key, message_ids):
    now = time.time()
    entries = [
        e
        for e in _ledger_load()
        if now - e.get("ts", 0) <= LEDGER_TTL_SECS
        and not (e.get("chat_id") == str(chat_id) and e.get("key") == key)
    ]
    entries.append(
        {
            "chat_id": str(chat_id),
            "key": key,
            "message_ids": list(message_ids),
            "ts": now,
        }
    )
    _ledger_save(entries[-LEDGER_MAX_ENTRIES:])


def send_message_once(chat_id, payload, idempotency_key=None):
    """One sendMessage call with optional idempotency.

    With a key, a repeat within 24h returns
    {"ok": True, "duplicate": True, "message_id": ..., "message_ids": [...]}
    without touching the API. Without a key, behaves exactly as before.
    """
    if idempotency_key:
        hit = _ledger_lookup(chat_id, idempotency_key)
        if hit is not None:
            ids = hit.get("message_ids", [])
            return {
                "ok": True,
                "duplicate": True,
                "message_id": ids[0] if ids else None,
                "message_ids": ids,
            }
    result = call("sendMessage", payload)
    if idempotency_key and result.get("ok"):
        _ledger_record(chat_id, idempotency_key, [result["result"]["message_id"]])
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError("redirect refused, verify the endpoint")


def build_url(method):
    # Do NOT use url_with_surrogate_path_segment here. It percent-encodes
    # the surrogate colon, and then the egress swap does not match it and
    # Telegram returns 404. Verified 2026-11-03: the raw surrogate in the
    # /bot{}/ segment swaps correctly and getMe returns 200. The value
    # placed here is only the hsurr: surrogate, never the real token.
    entry = dynamic_credential_entry(CREDENTIAL)
    surrogate = str(entry["surrogate"]).strip()
    return (BASE + method).replace("{}", surrogate, 1)


def call(method, payload=None):
    url = build_url(method)
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=35) as resp:
        return read_json_response(resp)


def build_file_url(file_path):
    entry = dynamic_credential_entry(CREDENTIAL)
    surrogate = str(entry["surrogate"]).strip()
    return ("https://api.telegram.org/file/bot{}/" + file_path).replace(
        "{}", surrogate, 1
    )


def download_file(file_id, out_path):
    result = call("getFile", {"file_id": file_id})
    if not result.get("ok"):
        raise RuntimeError(f"getFile failed: {result}")
    file_path = result["result"]["file_path"]
    url = build_file_url(file_path)
    request = urllib.request.Request(url)
    try:
        with urllib.request.build_opener(NoRedirect()).open(
            request, timeout=60
        ) as resp:
            data = resp.read()
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"file download failed: HTTP {exc.code} {exc.read()[:200]!r}"
        )
    with open(out_path, "wb") as fh:
        fh.write(data)
    return {"ok": True, "file_path": file_path, "bytes": len(data), "out": out_path}


def _split_keep(text, sep):
    """Split text on sep, keeping sep attached to the end of each piece.

    ''.join(pieces) == text always holds.
    """
    if not text:
        return []
    parts = text.split(sep)
    pieces = [p + sep for p in parts[:-1]]
    if parts[-1]:
        pieces.append(parts[-1])
    return pieces


def split_text(text, limit=TEXT_LIMIT):
    """Split text into chunks of at most `limit` characters.

    Preference order: paragraph breaks (\\n\\n), then single lines (\\n),
    then a hard cut. Separators stay attached to the preceding chunk, so
    ''.join(split_text(t, n)) == t and every chunk is <= n characters.
    """
    if limit <= 0:
        raise ValueError("limit must be positive")
    if not text:
        return []
    if len(text) <= limit:
        return [text]
    units = []
    for para in _split_keep(text, "\n\n"):
        if len(para) <= limit:
            units.append(para)
            continue
        for line in _split_keep(para, "\n"):
            if len(line) <= limit:
                units.append(line)
            else:
                for i in range(0, len(line), limit):
                    units.append(line[i : i + limit])
    chunks = []
    current = ""
    for unit in units:
        if len(current) + len(unit) <= limit:
            current += unit
        else:
            if current:
                chunks.append(current)
            current = unit
    if current:
        chunks.append(current)
    return chunks


def send_text(chat_id, text, reply_to_message_id=None, idempotency_key=None):
    """Send a text message, auto-splitting overlong texts.

    Short texts keep the original single sendMessage behaviour and return
    its raw result. Overlong texts are sent chunk by chunk in order and
    return a summary dict {ok, chunks, message_ids}. When
    reply_to_message_id is given, only the first (or only) chunk quotes
    that message. With idempotency_key, a repeat send within 24h returns
    the stored result instead of re-sending (single-chunk path; a
    multi-chunk send records only after ALL chunks succeed, so a retry
    after a mid-split failure may duplicate already-sent chunks).
    """
    if idempotency_key and len(text) <= TEXT_LIMIT:
        payload = {"chat_id": chat_id, "text": text}
        if reply_to_message_id is not None:
            payload["reply_to_message_id"] = reply_to_message_id
        return send_message_once(chat_id, payload, idempotency_key)
    chunks = split_text(text, TEXT_LIMIT)
    if len(chunks) <= 1:
        payload = {"chat_id": chat_id, "text": text}
        if reply_to_message_id is not None:
            payload["reply_to_message_id"] = reply_to_message_id
        return call("sendMessage", payload)
    message_ids = []
    for idx, chunk in enumerate(chunks):
        payload = {"chat_id": chat_id, "text": chunk}
        if idx == 0 and reply_to_message_id is not None:
            payload["reply_to_message_id"] = reply_to_message_id
        result = call("sendMessage", payload)
        if not result.get("ok"):
            raise RuntimeError(f"sendMessage chunk failed: {result}")
        message_ids.append(result["result"]["message_id"])
    if idempotency_key:
        _ledger_record(chat_id, idempotency_key, message_ids)
    return {"ok": True, "chunks": len(chunks), "message_ids": message_ids}


def call_multipart(method, fields, file_field, file_path):
    """POST a multipart/form-data request with one file part."""
    boundary = "----muse-tg-" + uuid.uuid4().hex
    body = bytearray()
    for name, value in fields.items():
        if value is None:
            continue
        body += f"--{boundary}\r\n".encode("utf-8")
        body += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(
            "utf-8"
        )
        body += str(value).encode("utf-8") + b"\r\n"
    filename = os.path.basename(file_path).replace('"', "_")
    content_type = (
        mimetypes.guess_type(filename)[0] or "application/octet-stream"
    )
    body += f"--{boundary}\r\n".encode("utf-8")
    body += (
        f'Content-Disposition: form-data; name="{file_field}"; '
        f'filename="{filename}"\r\n'
    ).encode("utf-8")
    body += f"Content-Type: {content_type}\r\n\r\n".encode("utf-8")
    with open(file_path, "rb") as fh:
        body += fh.read()
    body += b"\r\n"
    body += f"--{boundary}--\r\n".encode("utf-8")
    url = build_url(method)
    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    request = urllib.request.Request(url, data=bytes(body), headers=headers)
    with urllib.request.build_opener(NoRedirect()).open(
        request, timeout=180
    ) as resp:
        return read_json_response(resp)


def upload_file(method, file_field, chat_id, file_path, caption,
                reply_to_message_id=None):
    if not os.path.isfile(file_path):
        print(f"error: file not found: {file_path}", file=sys.stderr)
        sys.exit(2)
    size = os.path.getsize(file_path)
    if size > MAX_UPLOAD_BYTES:
        print(
            f"error: file too large: {size} bytes > {MAX_UPLOAD_BYTES} bytes limit",
            file=sys.stderr,
        )
        sys.exit(2)
    fields = {"chat_id": chat_id}
    if caption:
        fields["caption"] = caption
    if reply_to_message_id is not None:
        fields["reply_to_message_id"] = reply_to_message_id
    return call_multipart(method, fields, file_field, file_path)


def main():
    parser = argparse.ArgumentParser(description="Telegram Bot API helper")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("get-me")

    p_updates = sub.add_parser("get-updates")
    p_updates.add_argument("--offset", type=int, default=None)
    p_updates.add_argument("--timeout", type=int, default=0)

    p_send = sub.add_parser("send-message")
    p_send.add_argument("--chat-id", required=True)
    p_send.add_argument("--text", required=True)
    p_send.add_argument("--reply-to-message-id", type=int, default=None)
    p_send.add_argument("--idempotency-key", default=None,
                        help="repeat sends with the same key return the "
                        "stored result instead of re-sending (24h)")

    p_action = sub.add_parser("send-chat-action")
    p_action.add_argument("--chat-id", required=True)
    p_action.add_argument("--action", default="typing")

    p_edit = sub.add_parser("edit-message")
    p_edit.add_argument("--chat-id", required=True)
    p_edit.add_argument("--message-id", required=True, type=int)
    p_edit.add_argument("--text", required=True)

    p_sendfile = sub.add_parser("send-file")
    p_sendfile.add_argument("--chat-id", required=True)
    p_sendfile.add_argument("--path", required=True)
    p_sendfile.add_argument("--caption", default=None)
    p_sendfile.add_argument("--reply-to-message-id", type=int, default=None)

    p_sendphoto = sub.add_parser("send-photo-file")
    p_sendphoto.add_argument("--chat-id", required=True)
    p_sendphoto.add_argument("--path", required=True)
    p_sendphoto.add_argument("--caption", default=None)
    p_sendphoto.add_argument("--reply-to-message-id", type=int, default=None)

    p_approval = sub.add_parser("send-approval")
    p_approval.add_argument("--chat-id", required=True)
    p_approval.add_argument("--text", required=True)
    p_approval.add_argument("--approval-id", required=True)
    p_approval.add_argument("--reply-to-message-id", type=int, default=None)
    p_approval.add_argument("--idempotency-key", default=None)

    p_react = sub.add_parser("react")
    p_react.add_argument("--chat-id", required=True)
    p_react.add_argument("--message-id", required=True, type=int)
    p_react.add_argument("--emoji", default="👍")

    p_answer = sub.add_parser("answer-callback")
    p_answer.add_argument("--callback-query-id", required=True)
    p_answer.add_argument("--text", default=None)

    p_remove = sub.add_parser("remove-keyboard")
    p_remove.add_argument("--chat-id", required=True)
    p_remove.add_argument("--message-id", required=True, type=int)

    p_getfile = sub.add_parser("get-file")
    p_getfile.add_argument("--file-id", required=True)

    p_download = sub.add_parser("download-file")
    p_download.add_argument("--file-id", required=True)
    p_download.add_argument("--out", required=True)

    sub.add_parser("set-commands")
    sub.add_parser("get-commands")

    args = parser.parse_args()

    if args.command == "get-me":
        result = call("getMe")
    elif args.command == "get-updates":
        payload = {
            "timeout": args.timeout,
            "allowed_updates": ["message", "callback_query"],
        }
        if args.offset is not None:
            payload["offset"] = args.offset
        result = call("getUpdates", payload)
    elif args.command == "send-message":
        result = send_text(args.chat_id, args.text, args.reply_to_message_id,
                           args.idempotency_key)
    elif args.command == "send-chat-action":
        result = call(
            "sendChatAction", {"chat_id": args.chat_id, "action": args.action}
        )
    elif args.command == "edit-message":
        if len(args.text) > TEXT_LIMIT:
            print(
                f"error: edit text is {len(args.text)} characters, over the "
                f"{TEXT_LIMIT} limit; send a new message instead",
                file=sys.stderr,
            )
            sys.exit(2)
        result = call(
            "editMessageText",
            {
                "chat_id": args.chat_id,
                "message_id": args.message_id,
                "text": args.text,
            },
        )
    elif args.command == "send-file":
        result = upload_file(
            "sendDocument", "document", args.chat_id, args.path, args.caption,
            args.reply_to_message_id,
        )
    elif args.command == "send-photo-file":
        result = upload_file(
            "sendPhoto", "photo", args.chat_id, args.path, args.caption,
            args.reply_to_message_id,
        )
    elif args.command == "send-approval":
        # callback_data must be <=64 bytes; approval ids are kept short.
        reply_markup = {
            "inline_keyboard": [
                [
                    {
                        "text": "✅ 同意",
                        "callback_data": f"approve:{args.approval_id}",
                    },
                    {
                        "text": "❌ 拒绝",
                        "callback_data": f"deny:{args.approval_id}",
                    },
                ]
            ]
        }
        approval_payload = {
            "chat_id": args.chat_id,
            "text": args.text,
            "reply_markup": reply_markup,
        }
        if args.reply_to_message_id is not None:
            approval_payload["reply_to_message_id"] = args.reply_to_message_id
        result = send_message_once(
            args.chat_id, approval_payload,
            args.idempotency_key or f"approval:{args.approval_id}",
        )
    elif args.command == "react":
        result = call(
            "setMessageReaction",
            {
                "chat_id": args.chat_id,
                "message_id": args.message_id,
                "reaction": [{"type": "emoji", "emoji": args.emoji}],
            },
        )
    elif args.command == "answer-callback":
        payload = {"callback_query_id": args.callback_query_id}
        if args.text:
            payload["text"] = args.text
        result = call("answerCallbackQuery", payload)
    elif args.command == "remove-keyboard":
        result = call(
            "editMessageReplyMarkup",
            {
                "chat_id": args.chat_id,
                "message_id": args.message_id,
                "reply_markup": {"inline_keyboard": []},
            },
        )
    elif args.command == "get-file":
        result = call("getFile", {"file_id": args.file_id})
    elif args.command == "download-file":
        result = download_file(args.file_id, args.out)
    elif args.command == "set-commands":
        result = call(
            "setMyCommands",
            {
                "commands": [
                    {"command": "todos", "description": "查看未完成待办"},
                    {"command": "status", "description": "查看当前会话状态"},
                    {"command": "new", "description": "开启新会话"},
                    {"command": "reset", "description": "重置当前会话"},
                ]
            },
        )
    elif args.command == "get-commands":
        result = call("getMyCommands")
    else:
        parser.error("unknown command")

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
