#!/usr/bin/env python3
"""OpenAI-compatible mock LLM that scripts the integration file-exchange turn.

Backs the real `pi --mode rpc` child pi-sessiond spawns, so the VM check drives
a genuine agent turn offline. On a prompt containing the trigger it walks a
fixed tool-call chain, one tool per model round (keyed off how many tool
results are already in the history):

  0 -> github_get_repo            (autoRun; no approval)
  1 -> github_clone_to_workspace  (confirm-gated; the driver approves)
  2 -> bash (write AGENT_EDIT.md)  (native edit in the granted shared dir)
  3 -> github_open_pull_request   (confirm-gated; the driver approves)
  4 -> final assistant text

Adapted from checks/test-machine-mock-llm.py. usage: mock-llm.py [port]
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-model"
TRIGGER = "integration demo"
REPO = "octocat/hello"
# alice.uid is pinned to 1001 in the VM, so the shared workspace path the agent
# edits is deterministic: <%t>/spaces-integration-share/github/<repo-name>.
EDIT_PATH = "/run/user/1001/spaces-integration-share/github/hello/AGENT_EDIT.md"
EDIT_CMD = f"echo agent-was-here > {EDIT_PATH} && echo EDIT-OK"

STEPS = [
    ("github_get_repo", {"repo": REPO}),
    ("github_clone_to_workspace", {"repo": REPO}),
    ("bash", {"command": EDIT_CMD}),
    (
        "github_open_pull_request",
        {"repo": REPO, "title": "Agent edits", "body": "POC demo"},
    ),
]


def user_text(messages):
    parts = []
    for m in messages:
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                parts.append(c)
            elif isinstance(c, list):
                parts += [b.get("text", "") for b in c if isinstance(b, dict)]
    return "\n".join(parts).lower()


def plan(messages):
    """Return ("tool", name, args) or ("text", reply) for this round."""
    if TRIGGER not in user_text(messages):
        return ("text", "hello")
    n = sum(1 for m in messages if m.get("role") == "tool")
    if n < len(STEPS):
        name, args = STEPS[n]
        return ("tool", name, args)
    return ("text", "All done.")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a, **_k):
        pass

    def _json(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            self._json(
                json.dumps(
                    {
                        "object": "list",
                        "data": [
                            {
                                "id": MODEL_ID,
                                "object": "model",
                                "context_length": 32768,
                                "max_tokens": 4096,
                            }
                        ],
                    }
                ).encode()
            )
            return
        self.send_response(404)
        self.end_headers()

    def _tool_call(self, name, args):
        return {
            "index": 0,
            "id": f"call_{name}",
            "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)},
        }

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

        step = plan(req.get("messages", []))
        model = req.get("model", MODEL_ID)
        created = int(time.time())

        if not bool(req.get("stream")):
            if step[0] == "tool":
                msg = {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [self._tool_call(step[1], step[2])],
                }
                finish = "tool_calls"
            else:
                msg = {"role": "assistant", "content": step[1]}
                finish = "stop"
            self._json(
                json.dumps(
                    {
                        "id": "chatcmpl-mock",
                        "object": "chat.completion",
                        "created": created,
                        "model": model,
                        "choices": [
                            {"index": 0, "message": msg, "finish_reason": finish}
                        ],
                        "usage": {
                            "prompt_tokens": 1,
                            "completion_tokens": 1,
                            "total_tokens": 2,
                        },
                    }
                ).encode()
            )
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

        def chunk(delta, finish=None):
            return {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }

        emit(chunk({"role": "assistant"}))
        if step[0] == "tool":
            emit(chunk({"tool_calls": [self._tool_call(step[1], step[2])]}))
            emit(chunk({}, "tool_calls"))
        else:
            for piece in step[1].split():
                emit(chunk({"content": piece + " "}))
                time.sleep(0.01)
            emit(chunk({}, "stop"))
        done = b"data: [DONE]\n\n"
        self.wfile.write(f"{len(done):x}\r\n".encode())
        self.wfile.write(done)
        self.wfile.write(b"\r\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8012
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
