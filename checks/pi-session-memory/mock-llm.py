#!/usr/bin/env python3
"""OpenAI Chat Completions mock for the memory extension check.

Three distinct request shapes are served, discriminated by content:

  1. EXTRACTOR side-call (user message starts with the memory
     extension's EXTRACT_PROMPT). Replies with a single
     `KIND | SUBJECT | BODY` line on turn 1 ("blue" turn) and an empty
     reply on turn 2 ("question" turn), so the extension stores a fact
     after turn 1 but not after turn 2.

  2. User turn #1 ("I love blue."). Replies with plain assistant text.

  3. User turn #2 ("What's my favourite colour?"). Replies with text
     containing the recalled fact. The driver inspects the request body
     for the `<recalled_memories>` block to prove the extension's
     `before_agent_start` hook injected the canned recall result into
     the system prompt.

Every request body is written to $MOCK_REQUEST_LOG (NDJSON) so the
driver can make those assertions.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-memory-model"

EXTRACT_PROMPT_OPENER = "You extract durable memory items from one assistant turn."

TURN1_USER_HINT = "i love blue"
TURN2_USER_HINT = "favourite colour"

TURN1_REPLY = "Noted, you love blue."
TURN2_REPLY = "Your favourite colour is blue."
EXTRACT_TURN1_REPLY = "fact | favourite colour | blue"


def request_log_path():
    return os.environ.get("MOCK_REQUEST_LOG")


def log_request(payload):
    path = request_log_path()
    if not path:
        return
    with open(path, "a") as fh:
        fh.write(json.dumps(payload) + "\n")


def find_user_text(messages):
    """Return the most recent user message text, lowercased."""
    for m in reversed(messages or []):
        if m.get("role") != "user":
            continue
        content = m.get("content")
        if isinstance(content, str):
            return content.lower()
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    return (c.get("text") or "").lower()
    return ""


def is_extractor_call(messages):
    """The extractor wraps EXTRACT_PROMPT + <turn>...</turn>; first user
    message text starts with the EXTRACT_PROMPT opener."""
    for m in messages or []:
        if m.get("role") != "user":
            continue
        content = m.get("content")
        text = ""
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    text = c.get("text") or ""
                    break
        return text.strip().startswith(EXTRACT_PROMPT_OPENER)
    return False


def choose_reply(messages):
    if is_extractor_call(messages):
        # Inspect the wrapped <turn> payload to decide whether the side-
        # call is firing after turn 1 (store a fact) or turn 2 (no new
        # facts).
        body = json.dumps(messages).lower()
        if TURN1_USER_HINT in body:
            return EXTRACT_TURN1_REPLY
        return ""
    text = find_user_text(messages)
    if TURN1_USER_HINT in text:
        return TURN1_REPLY
    if TURN2_USER_HINT in text or "what color" in text or "what colour" in text:
        return TURN2_REPLY
    # Anything else: a short generic reply so pi sees non-empty
    # assistant text and progresses cleanly to agent_end. The driver
    # asserts on sediment-call and request-log shape, not on the
    # reply content here.
    return "Acknowledged."


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args, **_kwargs):
        pass

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps(
                {
                    "object": "list",
                    "data": [
                        {
                            "id": MODEL_ID,
                            "object": "model",
                            "context_length": 8192,
                            "max_tokens": 1024,
                        }
                    ],
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(length).decode())
        except Exception:
            self.send_response(400)
            self.end_headers()
            return

        log_request(req)

        messages = req.get("messages") or []
        reply = choose_reply(messages)
        stream = bool(req.get("stream"))
        created = int(time.time())

        if not stream:
            body = json.dumps(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion",
                    "created": created,
                    "model": MODEL_ID,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": reply},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 1,
                        "completion_tokens": max(1, len(reply.split())),
                        "total_tokens": 2,
                    },
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self._send_stream_headers()
        self._emit_chunk(
            {"delta": {"role": "assistant"}, "finish_reason": None}, created
        )
        if reply:
            self._emit_chunk(
                {"delta": {"content": reply}, "finish_reason": None}, created
            )
        self._emit_chunk({"delta": {}, "finish_reason": "stop"}, created)
        self._end_stream()

    def _send_stream_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _emit_chunk(self, choice_payload, created):
        payload = {
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": created,
            "model": MODEL_ID,
            "choices": [dict(choice_payload, index=0)],
        }
        line = f"data: {json.dumps(payload)}\n\n".encode()
        self.wfile.write(f"{len(line):x}\r\n".encode())
        self.wfile.write(line)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _end_stream(self):
        done = b"data: [DONE]\n\n"
        self.wfile.write(f"{len(done):x}\r\n".encode())
        self.wfile.write(done)
        self.wfile.write(b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    host, port = server.server_address
    sys.stdout.write(f"http://{host}:{port}\n")
    sys.stdout.flush()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        sys.stdin.read()
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
