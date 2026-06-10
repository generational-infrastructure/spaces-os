#!/usr/bin/env python3
"""OpenAI-compatible mock LLM for test-machine's chat round-trip.

Pi-chat's local mode would otherwise run qwen2.5:0.5b on the QEMU CPU,
which can't prefill pi's multi-thousand-token system prompt within a
sane test budget. The chat round-trip test exercises the *plumbing*
(shell IPC → PiSession → WebSocket → pi-sessiond → pi →
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


EXTRACT_PROMPT_OPENER = "You extract durable memory items from one assistant turn."
MEMORY_FACT_SUBJECT = "hobby"
MEMORY_FACT_BODY = "mountain biking"
MEMORY_TRIGGER = MEMORY_FACT_BODY

# Loopback-executor sandbox probe (test-machine-ws-probe.py): on this
# trigger, emit a bash tool_call that tries to read the user's HOME.
# bash-confirm gates it; the probe approves; ProtectHome=tmpfs in the
# per-command unit must hide the marker, so the fallback echo fires.
HOME_PROBE_TRIGGER = "run the home probe"
HOME_PROBE_CMD = "cat /home/test/secret-marker || echo HOME-DENIED"


def system_text(messages):
    parts = []
    for m in messages:
        if m.get("role") != "system":
            continue
        content = m.get("content", "")
        if isinstance(content, list):
            parts.extend(str(b.get("text", "")) for b in content if isinstance(b, dict))
        else:
            parts.append(str(content))
    return "\n".join(parts)


def user_text(messages):
    for m in reversed(messages):
        if m.get("role") != "user":
            continue
        content = m.get("content", "")
        if isinstance(content, list):
            return " ".join(
                str(b.get("text", "")) for b in content if isinstance(b, dict)
            )
        return str(content)
    return ""


def pick_reply(messages):
    sys_text = system_text(messages)
    last_user = user_text(messages)
    lower = last_user.lower()

    # Memory-extension side-call: the user message wraps a scrubbed turn
    # behind EXTRACT_PROMPT. If that turn mentioned the trigger phrase,
    # emit a parseable fact line so the extension stores it.
    if lower.startswith(EXTRACT_PROMPT_OPENER.lower()):
        if MEMORY_TRIGGER in lower:
            return f"pref | {MEMORY_FACT_SUBJECT} | {MEMORY_FACT_BODY}"
        return ""

    # Recall-driven reply: when the memory extension injects a
    # <recalled_memories> block carrying the hobby fact, surface it in
    # the answer. The driver asserts the body string is in the reply, so
    # recall regressions are caught even if the model output drifts.
    if "<recalled_memories>" in sys_text and MEMORY_FACT_BODY in sys_text:
        if "hobby" in lower or "remember" in lower:
            return f"Per your memory, your hobby is {MEMORY_FACT_BODY}."

    # First leg of the memory subtest: user states the fact; mock
    # acknowledges so pi reaches agent_end and triggers the extractor.
    if MEMORY_TRIGGER in lower:
        return f"Noted: {MEMORY_FACT_BODY}."

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

        messages = req.get("messages", [])
        lower_user = user_text(messages).lower()
        has_tool_result = any(m.get("role") == "tool" for m in messages)
        probe = HOME_PROBE_TRIGGER in lower_user
        reply = "Done." if (probe and has_tool_result) else pick_reply(messages)
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

        if probe and not has_tool_result:
            emit(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_home_probe",
                                        "type": "function",
                                        "function": {
                                            "name": "bash",
                                            "arguments": json.dumps(
                                                {"command": HOME_PROBE_CMD}
                                            ),
                                        },
                                    }
                                ]
                            },
                            "finish_reason": None,
                        }
                    ],
                }
            )
            emit(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [
                        {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
                    ],
                }
            )
            done = b"data: [DONE]\n\n"
            self.wfile.write(f"{len(done):x}\r\n".encode())
            self.wfile.write(done)
            self.wfile.write(b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
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
