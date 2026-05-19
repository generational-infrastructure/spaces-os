#!/usr/bin/env python3
"""Minimal OpenAI Chat Completions mock used by the streaming-pi-e2e
check. Speaks just enough of the protocol for pi-mono's
"openai-completions" provider to be happy:

  - GET  /v1/models                  → one fake model entry
  - POST /v1/chat/completions        → SSE stream of text chunks

The streaming response deliberately pauses between chunks so the
driver's wall-clock assertions can distinguish "real streaming"
from "buffer then flush all at once".

Listens on 127.0.0.1 at a port chosen by the kernel and prints the
URL ("http://127.0.0.1:PORT") to stdout so the spawning driver can
discover it before launching pi.
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-model"
CHUNKS = ["Hello", ", ", "world", "!"]
CHUNK_GAP_S = 0.1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args, **_kwargs):
        # Quiet by default; the driver tee's pi stderr for debugging.
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
                            "context_length": 32768,
                            "max_tokens": 4096,
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

        stream = bool(req.get("stream"))
        if not stream:
            # Non-stream completion: respond with the full text.
            full = "".join(CHUNKS)
            body = json.dumps(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion",
                    "created": int(time.time()),
                    "model": MODEL_ID,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": full},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 1,
                        "completion_tokens": 4,
                        "total_tokens": 5,
                    },
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Streaming response.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def emit(payload):
            line = f"data: {json.dumps(payload)}\n\n".encode()
            # Manual chunked framing.
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
                "model": MODEL_ID,
                "choices": [
                    {"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}
                ],
            }
        )

        for chunk in CHUNKS:
            emit(
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": MODEL_ID,
                    "choices": [
                        {"index": 0, "delta": {"content": chunk}, "finish_reason": None}
                    ],
                }
            )
            time.sleep(CHUNK_GAP_S)

        emit(
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion.chunk",
                "created": created,
                "model": MODEL_ID,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }
        )
        # Terminating sentinel.
        done = b"data: [DONE]\n\n"
        self.wfile.write(f"{len(done):x}\r\n".encode())
        self.wfile.write(done)
        self.wfile.write(b"\r\n")
        # Zero-length chunk closes the stream.
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    host, port = server.server_address
    sys.stdout.write(f"http://{host}:{port}\n")
    sys.stdout.flush()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # Block until parent closes stdin.
    try:
        sys.stdin.read()
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
