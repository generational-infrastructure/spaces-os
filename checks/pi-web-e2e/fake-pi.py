#!/usr/bin/env python3
"""Fake `pi --mode rpc` for the pi-web headless-browser E2E.

A normal prompt streams a short assistant reply (text_start / text_delta /
text_end + agent_end) so the PWA renders a message bubble. A prompt whose
message contains "confirm" opens a confirm side channel instead; the following
extension_ui_response ends the turn (so the PWA's Allow button is exercised).

Reads NDJSON commands on stdin, writes NDJSON events on stdout. Ignores argv
(the daemon passes pi's real flags, which don't apply here).
"""

import json
import sys

REPLY = "Hello from pi-web!"


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def stream_reply():
    emit({"type": "agent_start"})
    emit({"type": "message_update", "assistantMessageEvent": {"type": "text_start"}})
    for chunk in (REPLY[:6], REPLY[6:]):  # arrives in two deltas
        emit(
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_delta", "delta": chunk},
            }
        )
    emit(
        {
            "type": "message_update",
            "assistantMessageEvent": {"type": "text_end", "content": REPLY},
        }
    )
    emit(
        {
            "type": "agent_end",
            "messages": [
                {"role": "assistant", "content": [{"type": "text", "text": REPLY}]}
            ],
        }
    )


def main():
    while True:
        line = sys.stdin.readline()
        if not line:
            return 0  # EOF: daemon closed stdin
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = cmd.get("type")
        if kind == "prompt":
            if "confirm" in str(cmd.get("message", "")):
                emit({"type": "agent_start"})
                emit(
                    {
                        "type": "extension_ui_request",
                        "id": "e2e-1",
                        "method": "confirm",
                        "title": "Run it?",
                        "message": "bash: echo hi",
                    }
                )
            else:
                stream_reply()
        elif kind == "extension_ui_response":
            emit(
                {
                    "type": "agent_end",
                    "messages": [
                        {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "ok"}],
                        }
                    ],
                }
            )


if __name__ == "__main__":
    sys.exit(main())
