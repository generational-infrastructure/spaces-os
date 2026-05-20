#!/usr/bin/env python3
"""OpenAI Chat Completions mock for the bash-confirm e2e check.

Asks pi to run a bash command on the first turn, returns a short text
reply once the tool result lands. Behaviour depends only on whether
the inbound request's `messages` already contains a tool result, so
the mock is stateless across requests.

Listens on 127.0.0.1, prints `http://host:port` to stdout, blocks on
stdin until the parent driver closes us.
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-bash-model"
BASH_COMMAND = "printf hello-from-bash"
FINAL_TEXT = "Ran the command."


def has_tool_result(messages):
    """Detect whether pi has already fed us a tool result for the bash call."""
    for m in messages:
        role = m.get("role")
        # OpenAI tool-result role (used by openai-completions API).
        if role == "tool":
            return True
        # Anthropic-style tool_result content blocks (some compat layers).
        content = m.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") in (
                    "tool_result",
                    "toolResult",
                ):
                    return True
    return False


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

        is_followup = has_tool_result(req.get("messages") or [])
        stream = bool(req.get("stream"))
        created = int(time.time())

        if not is_followup:
            # Issue a single bash tool call.
            tc = {
                "id": "call-bash-1",
                "type": "function",
                "function": {
                    "name": "bash",
                    "arguments": json.dumps({"command": BASH_COMMAND}),
                },
            }
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
                                "message": {
                                    "role": "assistant",
                                    "content": None,
                                    "tool_calls": [tc],
                                },
                                "finish_reason": "tool_calls",
                            }
                        ],
                        "usage": {
                            "prompt_tokens": 1,
                            "completion_tokens": 1,
                            "total_tokens": 2,
                        },
                    }
                ).encode()
                self._send_json(body)
                return

            self._send_stream_headers()
            self._emit_chunk(
                {"delta": {"role": "assistant"}, "finish_reason": None}, created
            )
            # Stream the tool call in one delta — many OpenAI servers
            # do, and pi handles both shapes.
            stream_tc = {
                "index": 0,
                "id": tc["id"],
                "type": "function",
                "function": {"name": "bash", "arguments": tc["function"]["arguments"]},
            }
            self._emit_chunk(
                {"delta": {"tool_calls": [stream_tc]}, "finish_reason": None}, created
            )
            self._emit_chunk({"delta": {}, "finish_reason": "tool_calls"}, created)
            self._end_stream()
            return

        # Follow-up turn: short text reply.
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
                            "message": {"role": "assistant", "content": FINAL_TEXT},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 2,
                        "completion_tokens": len(FINAL_TEXT.split()),
                        "total_tokens": 3,
                    },
                }
            ).encode()
            self._send_json(body)
            return

        self._send_stream_headers()
        self._emit_chunk(
            {"delta": {"role": "assistant"}, "finish_reason": None}, created
        )
        for piece in FINAL_TEXT.split():
            self._emit_chunk(
                {"delta": {"content": piece + " "}, "finish_reason": None}, created
            )
            time.sleep(0.02)
        self._emit_chunk({"delta": {}, "finish_reason": "stop"}, created)
        self._end_stream()

    def _send_json(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
