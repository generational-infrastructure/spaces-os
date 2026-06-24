#!/usr/bin/env python3
"""Stub `pi --mode rpc` child for daemon-level drive-path checks.

Speaks pi's JSON-line rpc protocol on stdio so the real pi-sessiond supervisor
can be driven end-to-end without a model, network, or the real pi binary:
correlates command responses by id, streams events around a prompt, and drives
one extension_ui (approval) round-trip when a prompt asks for it. argv (the
--session-id / --provider / --model the supervisor passes) is accepted and
ignored — this stub is stateless.
"""

import json
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def handle(cmd):
    t = cmd.get("type")
    cid = cmd.get("id")
    if t == "get_available_models":
        emit(
            {
                "type": "response",
                "command": "get_available_models",
                "id": cid,
                "success": True,
                "data": {
                    "models": [{"provider": "local", "id": "stub", "name": "Stub"}]
                },
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
    elif t == "set_model":
        emit(
            {
                "type": "response",
                "command": "set_model",
                "id": cid,
                "success": True,
                "data": {"provider": cmd.get("provider"), "id": cmd.get("modelId")},
            }
        )
    elif t == "set_thinking_level":
        emit(
            {
                "type": "response",
                "command": "set_thinking_level",
                "id": cid,
                "success": True,
            }
        )
    elif t == "abort":
        emit({"type": "response", "command": "abort", "id": cid, "success": True})
    elif t == "prompt":
        emit({"type": "agent_start"})
        emit({"type": "response", "command": "prompt", "id": cid, "success": True})
        msg = cmd.get("message", "")
        if "CONFIRM" in msg:
            # Park on an approval; agent_end is deferred until the answer.
            emit(
                {
                    "type": "extension_ui_request",
                    "id": "ui-stub",
                    "method": "confirm",
                    "title": "Proceed?",
                    "message": msg,
                }
            )
        else:
            emit({"type": "assistant_message", "text": "stub reply: " + msg})
            emit({"type": "agent_end"})
    elif t == "extension_ui_response":
        emit(
            {
                "type": "assistant_message",
                "text": "confirmed=" + str(cmd.get("confirmed")),
            }
        )
        emit({"type": "agent_end"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(cmd)


if __name__ == "__main__":
    main()
