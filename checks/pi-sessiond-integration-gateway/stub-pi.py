#!/usr/bin/env python3
"""Stub `pi --mode rpc` child for the integration-gateway check.

Stands in for real pi + the spaces-integrations extension: on a prompt
`INTCALL <json>` (json = { integration, tool, args }) it emits the exact
extension_ui `input` frame the real extension emits — title is the
integration-call sentinel, placeholder is the JSON payload — and defers
agent_end until the supervisor's gateway replies extension_ui_response{value}.
It then surfaces that value as an assistant_message `RESULT <value>` so the
driver can read the gateway's verdict. argv is accepted and ignored.
"""

import json
import sys

# MUST match packages/pi-sessiond/integrations.ts (INTEGRATION_CALL_TITLE).
INTEGRATION_CALL_TITLE = "spaces.integration-call"


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
    elif t == "abort":
        emit({"type": "response", "command": "abort", "id": cid, "success": True})
    elif t == "prompt":
        emit({"type": "agent_start"})
        emit({"type": "response", "command": "prompt", "id": cid, "success": True})
        msg = cmd.get("message", "")
        if msg.startswith("INTCALL "):
            # Forward a tool call exactly as the spaces-integrations extension's
            # ctx.ui.input(...) does; agent_end waits for the gateway's reply.
            emit(
                {
                    "type": "extension_ui_request",
                    "id": "ui-int",
                    "method": "input",
                    "title": INTEGRATION_CALL_TITLE,
                    "placeholder": msg[len("INTCALL ") :],
                }
            )
        else:
            emit({"type": "assistant_message", "text": "stub reply: " + msg})
            emit({"type": "agent_end"})
    elif t == "extension_ui_response":
        # The gateway's reply rides `value` (JSON { text, isError }).
        emit(
            {"type": "assistant_message", "text": "RESULT " + (cmd.get("value") or "")}
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
