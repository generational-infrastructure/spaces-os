#!/usr/bin/env python3
"""Fake `pi --mode rpc` for the daemon side-channel test.

On a `prompt` it opens a side channel — emits agent_start then
extension_ui_request{method:confirm} — and blocks. Every
extension_ui_response it then reads is counted and echoed back as a
`confirm_received{n, confirmed}` event; the FIRST one ends the turn
(agent_end). The daemon's first-answer-wins dedup must ensure pi never sees
more than one response, i.e. `n` never exceeds 1 even if two clients answer.

Reads NDJSON commands on stdin; writes NDJSON events on stdout. Ignores its
argv (the daemon passes pi's real flags, which don't apply here).
"""

import json
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    n = 0
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
            emit({"type": "agent_start"})
            emit(
                {
                    "type": "extension_ui_request",
                    "id": "sc-1",
                    "method": "confirm",
                    "title": "Run it?",
                    "message": "bash: echo hi",
                }
            )
        elif kind == "extension_ui_response":
            n += 1
            emit({"type": "confirm_received", "n": n, "confirmed": cmd.get("confirmed")})
            if n == 1:
                emit(
                    {
                        "type": "agent_end",
                        "messages": [
                            {
                                "role": "assistant",
                                "content": [{"type": "text", "text": "done"}],
                            }
                        ],
                    }
                )


if __name__ == "__main__":
    sys.exit(main())
