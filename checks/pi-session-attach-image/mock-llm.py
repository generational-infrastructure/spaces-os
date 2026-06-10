#!/usr/bin/env python3
"""Recording OpenAI-compatible mock for the attach-image WS check.

Stands in for the executor's llama-swap, with one twist over the other mock
LLMs: every /v1/chat/completions request BODY is appended (one raw line per
request) to the capture file in argv[2]. The driver greps that capture for the
tiny PNG's exact base64 payload to prove the panel-encoded image rode the WS
`prompt` command through pi-sessiond and the pi SDK all the way into the LLM
request.

  GET  /v1/models           -> [mock-model]  (pi-sessiond's provider discovery
                               registers it under provider "local")
  POST /v1/chat/completions -> body recorded, then a short streamed reply

Usage: mock-llm.py <port> <capture_file>
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = "mock-model"
CAPTURE_PATH = ""
CAPTURE_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_a, **_k):
        pass

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/models":
            body = json.dumps(
                {"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]}
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
        raw = self.rfile.read(length)
        # Record the verbatim request body; the driver asserts the multimodal
        # image part (the base64 PNG) is in here. JSON bodies carry no raw
        # newlines, so one line per request keeps the capture greppable.
        with CAPTURE_LOCK:
            with open(CAPTURE_PATH, "ab") as fh:
                fh.write(raw + b"\n")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        base = {
            "id": "chatcmpl-mock",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": MODEL_ID,
        }

        def emit(payload):
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        for piece in ["I can see", " the image."]:
            emit(
                {
                    **base,
                    "choices": [
                        {"index": 0, "delta": {"content": piece}, "finish_reason": None}
                    ],
                }
            )
            time.sleep(0.02)
        emit({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    global CAPTURE_PATH
    port = int(sys.argv[1])
    CAPTURE_PATH = sys.argv[2]
    open(CAPTURE_PATH, "wb").close()
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
