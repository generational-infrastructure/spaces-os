#!/usr/bin/env python3
"""OpenAI Chat Completions mock for the notifications skill check.

First turn: emit a single bash tool call that runs the `notifications`
CLI. Second turn (once pi has fed us the tool result): emit assistant
text that includes the raw tool output verbatim, so the driver can
verify pi actually executed the CLI and surfaced the seeded entry.

Listens on 127.0.0.1, prints `http://host:port` to stdout, then blocks
on stdin until the parent driver closes us.
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-notifications-model"
BASH_COMMAND = "notifications list --json --limit 2"


def has_tool_result(messages):
    for m in messages:
        if m.get("role") == "tool":
            return True
        content = m.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") in (
                    "tool_result",
                    "toolResult",
                ):
                    return True
    return False


def last_tool_output(messages):
    """Return whatever pi sent us as the bash tool's stdout/stderr."""
    for m in reversed(messages):
        if m.get("role") == "tool":
            content = m.get("content")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                parts = []
                for c in content:
                    if isinstance(c, dict):
                        text = c.get("text") or c.get("output") or ""
                        if text:
                            parts.append(text)
                if parts:
                    return "\n".join(parts)
        content = m.get("content")
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") in (
                    "tool_result",
                    "toolResult",
                ):
                    payload = c.get("content") or c.get("output") or c.get("text")
                    if isinstance(payload, str):
                        return payload
                    if isinstance(payload, list):
                        parts = []
                        for p in payload:
                            if isinstance(p, dict):
                                t = p.get("text") or ""
                                if t:
                                    parts.append(t)
                        if parts:
                            return "\n".join(parts)
    return ""


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

        messages = req.get("messages") or []
        is_followup = has_tool_result(messages)
        stream = bool(req.get("stream"))
        created = int(time.time())

        if not is_followup:
            tc = {
                "id": "call-notif-1",
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
            stream_tc = {
                "index": 0,
                "id": tc["id"],
                "type": "function",
                "function": {
                    "name": "bash",
                    "arguments": tc["function"]["arguments"],
                },
            }
            self._emit_chunk(
                {"delta": {"tool_calls": [stream_tc]}, "finish_reason": None}, created
            )
            self._emit_chunk({"delta": {}, "finish_reason": "tool_calls"}, created)
            self._end_stream()
            return

        # Follow-up turn — echo the tool output back as assistant text so
        # the driver can verify pi actually executed the CLI against the
        # seeded notifications fixture.
        output = last_tool_output(messages).strip() or "(no tool output)"
        final_text = f"NOTIFS_BEGIN\n{output}\nNOTIFS_END"

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
                                "content": final_text,
                            },
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 2,
                        "completion_tokens": len(final_text.split()),
                        "total_tokens": 2 + len(final_text.split()),
                    },
                }
            ).encode()
            self._send_json(body)
            return

        self._send_stream_headers()
        self._emit_chunk(
            {"delta": {"role": "assistant"}, "finish_reason": None}, created
        )
        # Emit the final text in one chunk; pi handles arbitrary chunking.
        self._emit_chunk(
            {"delta": {"content": final_text}, "finish_reason": None}, created
        )
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
        self.end_headers()

    def _emit_chunk(self, choice, created):
        payload = {
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": created,
            "model": MODEL_ID,
            "choices": [{"index": 0, **choice}],
        }
        line = "data: " + json.dumps(payload) + "\n\n"
        self.wfile.write(line.encode())
        self.wfile.flush()

    def _end_stream(self):
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    host, port = server.server_address
    print(f"http://{host}:{port}", flush=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        # Wait until stdin closes (parent driver shutdown).
        sys.stdin.read()
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
