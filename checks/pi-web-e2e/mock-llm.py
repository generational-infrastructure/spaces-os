#!/usr/bin/env python3
"""OpenAI-compatible mock for the pi-web headless-browser E2E.

Branches on the conversation so one mock drives both PWA scenarios:
  - a prompt containing "confirm" -> a `bash` tool_call (bash-confirm then gates
    it -> the confirm card); after the tool result, a short final reply.
  - any other prompt            -> streams "Hello, world!".
Serves GET /v1/models and POST /v1/chat/completions (SSE)."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-model"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a, **_k):
        pass

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps({"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]}).encode()
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
        req = json.loads(self.rfile.read(length).decode())
        messages = req.get("messages") or []
        has_tool_result = any(m.get("role") == "tool" for m in messages)
        last_user = ""
        for m in messages:
            if m.get("role") == "user":
                c = m.get("content")
                last_user = c if isinstance(c, str) else json.dumps(c)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        created = int(time.time())
        base = {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": created, "model": MODEL_ID}

        def emit(payload):
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        if (not has_tool_result) and "confirm" in last_user.lower():
            emit({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [
                {"index": 0, "id": "call_bash_1", "type": "function",
                 "function": {"name": "bash", "arguments": json.dumps({"command": "echo confirmed"})}}
            ]}, "finish_reason": None}]})
            emit({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
        else:
            reply = "Ran it." if has_tool_result else "Hello, world!"
            for piece in [reply[: len(reply) // 2], reply[len(reply) // 2 :]]:
                emit({**base, "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]})
                time.sleep(0.02)
            emit({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8013
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
