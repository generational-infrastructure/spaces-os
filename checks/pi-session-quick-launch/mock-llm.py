#!/usr/bin/env python3
"""Streaming OpenAI Chat Completions mock for the quick-launch checks.

Speaks just enough of the protocol for pi's "openai-completions"
provider:

  - GET  /v1/models            → the model list from $MOCK_MODELS_JSON
                                 (a JSON array of ids; default ["mock-model"])
  - POST /v1/chat/completions  → SSE stream of assistant text chunks

Two behaviours the checks rely on:

  * Normal turn: streams REPLY ("Background task complete.") and ends,
    so pi reaches agent_end promptly. The driver asserts the streamed
    assistant text and the completion notification.

  * Held turn: if the latest user message contains the marker "HOLD"
    (case-insensitive) and $MOCK_HOLD_FILE does not yet exist, the
    handler streams the opening chunk then BLOCKS before the final
    chunk until that file appears (or a generous timeout). This keeps
    the session mid-turn (busy) so the idle-reap check can prove a
    streaming session survives the reaper, then release it.

Every request body is appended to $MOCK_REQUEST_LOG (NDJSON) when set —
including the chat request's `model`, which the model-directive check
asserts on to prove `set_model` landed before the prompt was sent.
The URL is printed to stdout so the spawning driver can discover it.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLY = "Background task complete."
HOLD_MARKER = "hold"
HOLD_TIMEOUT_S = 120


def model_ids():
    raw = os.environ.get("MOCK_MODELS_JSON")
    if not raw:
        return ["mock-model"]
    ids = json.loads(raw)
    if not isinstance(ids, list) or not ids:
        raise ValueError(f"MOCK_MODELS_JSON must be a non-empty list, got {raw!r}")
    return [str(i) for i in ids]


def log_request(payload):
    path = os.environ.get("MOCK_REQUEST_LOG")
    if not path:
        return
    with open(path, "a") as fh:
        fh.write(json.dumps(payload) + "\n")


def latest_user_text(messages):
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


def wait_for_release():
    hold_file = os.environ.get("MOCK_HOLD_FILE")
    if not hold_file:
        return
    deadline = time.monotonic() + HOLD_TIMEOUT_S
    while not os.path.exists(hold_file) and time.monotonic() < deadline:
        time.sleep(0.05)


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
                            "id": mid,
                            "object": "model",
                            "context_length": 32768,
                            "max_tokens": 4096,
                        }
                        for mid in model_ids()
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
        user_text = latest_user_text(messages)
        held = HOLD_MARKER in user_text
        created = int(time.time())
        # Echo whichever model pi selected so a multi-model deployment
        # round-trips faithfully; the request log is what the directive
        # check asserts on.
        model = req.get("model") or model_ids()[0]

        if not req.get("stream"):
            if held:
                wait_for_release()
            body = json.dumps(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion",
                    "created": created,
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": REPLY},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 1,
                        "completion_tokens": max(1, len(REPLY.split())),
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
            {"delta": {"role": "assistant"}, "finish_reason": None}, created, model
        )
        # Stream the opening words, then (for a held turn) block before
        # the closing chunk so the agent stays mid-turn until released.
        self._emit_chunk(
            {"delta": {"content": REPLY}, "finish_reason": None}, created, model
        )
        if held:
            wait_for_release()
        self._emit_chunk({"delta": {}, "finish_reason": "stop"}, created, model)
        self._end_stream()

    def _send_stream_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _emit_chunk(self, choice_payload, created, model):
        payload = {
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [dict(choice_payload, index=0)],
        }
        line = f"data: {json.dumps(payload)}\n\n".encode()
        try:
            self.wfile.write(f"{len(line):x}\r\n".encode())
            self.wfile.write(line)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
        except BrokenPipeError:
            pass

    def _end_stream(self):
        done = b"data: [DONE]\n\n"
        try:
            self.wfile.write(f"{len(done):x}\r\n".encode())
            self.wfile.write(done)
            self.wfile.write(b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except BrokenPipeError:
            pass


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
