#!/usr/bin/env python3
"""Stub `pi --mode rpc` child that RECORDS its spawn argv.

Unlike the stateless drive-path stub, this one appends one JSON line of
its argv to $STUB_PI_LOG_DIR/spawn-<session-id>.log on startup — the
model-persistence check asserts which --provider/--model the supervisor
passed on create and on cold resume. STUB_PI_LOG_DIR rides
SPACES_SESSIOND_SESSION_ENV (the unit gets a fresh env, so plain
inheritance never reaches the child).

The rpc surface is the minimum the daemon's dispatcher round-trips:
correlated responses for set_model / get_state / get_messages.
"""

import json
import os
import sys


def record_spawn() -> None:
    log_dir = os.environ.get("STUB_PI_LOG_DIR", "")
    if not log_dir:
        return
    argv = sys.argv[1:]
    sid = ""
    if "--session-id" in argv:
        try:
            sid = argv[argv.index("--session-id") + 1]
        except IndexError:
            pass
    path = os.path.join(log_dir, f"spawn-{sid or 'unknown'}.log")
    with open(path, "a") as fh:
        fh.write(json.dumps(argv) + "\n")


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handle(cmd):
    t = cmd.get("type")
    cid = cmd.get("id")
    if t == "set_model":
        emit(
            {
                "type": "response",
                "command": "set_model",
                "id": cid,
                "success": True,
                "data": {"provider": cmd.get("provider"), "id": cmd.get("modelId")},
            }
        )
    elif t == "get_state":
        emit(
            {
                "type": "response",
                "command": "get_state",
                "id": cid,
                "success": True,
                "data": {
                    "model": {"provider": "local", "id": "stub"},
                    "messageCount": 0,
                    "isStreaming": False,
                    "sessionId": "stub",
                },
            }
        )
    elif t == "get_messages":
        emit(
            {
                "type": "response",
                "command": "get_messages",
                "id": cid,
                "success": True,
                "data": {"messages": []},
            }
        )


def main():
    record_spawn()
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(cmd)


if __name__ == "__main__":
    main()
