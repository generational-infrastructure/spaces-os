#!/usr/bin/env python3
"""OpenAI-compatible mock LLM for test-machine's chat round-trip.

Pi-chat's local mode would otherwise run qwen2.5:0.5b on the QEMU CPU,
which can't prefill pi's multi-thousand-token system prompt within a
sane test budget. The chat round-trip test exercises the *plumbing*
(noctalia plugin IPC → PiSession → systemd-run service → pi RPC →
OpenAI client → server), not the model itself; this mock keeps that
plumbing honest while making the e2e completable in seconds.

Wire format: just enough of the OpenAI Chat Completions API to satisfy
pi's "openai-completions" provider:

  - GET  /v1/models                  → fake model list
  - POST /v1/chat/completions        → SSE stream of text chunks

Reply policy: looks at the last user message and answers based on
simple keyword matching, so the test's content assertions (e.g.
"What color is the sky?" → "blue") still hold.
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8012
MODELS = ["qwen2.5:0.5b", "smollm"]


def pick_reply(messages):
    last_user = ""
    for m in reversed(messages):
        if m.get("role") == "user":
            content = m.get("content", "")
            if isinstance(content, list):
                # pi may send structured content blocks
                last_user = " ".join(
                    str(b.get("text", "")) for b in content if isinstance(b, dict)
                )
            else:
                last_user = str(content)
            break
    lower = last_user.lower()
    if "sky" in lower:
        return "blue"
    return "hello back"


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
                        for mid in MODELS
                    ],
                }
            ).encode()
            self._respond_json(body)
            return
        self.send_response(404)
        self.end_headers()

    def _respond_json(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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

        reply = pick_reply(req.get("messages", []))
        model = req.get("model", MODELS[0])
        stream = bool(req.get("stream"))

        if not stream:
            body = json.dumps(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": reply},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 1,
                        "completion_tokens": len(reply.split()),
                        "total_tokens": 1 + len(reply.split()),
                    },
                }
            ).encode()
            self._respond_json(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def emit(payload):
            line = f"data: {json.dumps(payload)}\n\n".encode()
            self.wfile.write(f"{len(line):x}\r\n".encode())
            self.wfile.write(line)
            self.wfile.write(b"\r\n")
            self.wfile.flush()

        created = int(time.time())
        emit(
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    {"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}
                ],
            }
        )
        for piece in reply.split():
            emit(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": piece + " "},
                            "finish_reason": None,
                        }
                    ],
                }
            )
            time.sleep(0.01)
        emit(
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }
        )
        done = b"data: [DONE]\n\n"
        self.wfile.write(f"{len(done):x}\r\n".encode())
        self.wfile.write(done)
        self.wfile.write(b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stdout.write(f"mock-llm listening on http://127.0.0.1:{PORT}\n")
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
