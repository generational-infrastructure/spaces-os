#!/usr/bin/env python3
"""Remote-pi client driver: open a session on a remote pi-sessiond executor
over the WebSocket envelope protocol (docs/remote-pi-design.md §12) and drive
one streaming turn.

Runs on the *client* node and targets the *server* node's executor:

    driver.py <ws_url> <token> [executor-id]

Asserts the cross-machine contract:
  - hello {token}     -> welcome {connectionId}
  - create_session    -> attached {sessionId, seq}
  - command {prompt}  -> a stream of event {payload: pi event} envelopes
                         carrying >=2 text_delta deltas that concatenate to
                         the mock LLM's reply, terminated by agent_end.

Prints OK and exits 0 on success; prints FAIL: <reason> to stderr and exits 1
otherwise. The streaming assertions mirror checks/pi-rpc-streaming/driver.py,
but the transport is the daemon's WebSocket envelope across two VMs rather
than a local pipe.
"""

import asyncio
import json
import sys

import websockets

EXPECTED_PIECES = ["Hello", ", ", "world", "!"]
EXPECTED_REPLY = "".join(EXPECTED_PIECES)
RECV_TIMEOUT_S = 60


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


async def recv_kind(ws, want):
    """Read envelopes until one with kind == want; fail on `error`."""
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=RECV_TIMEOUT_S)
        msg = json.loads(raw)
        kind = msg.get("kind")
        if kind == want:
            return msg
        if kind == "error":
            fail(f"server error while awaiting {want!r}: {msg}")
        # Ignore unrelated envelopes (e.g. `sessions` broadcasts).


def agent_end_text(ev):
    for m in ev.get("messages") or []:
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        content = m.get("content")
        if not isinstance(content, list):
            continue
        text = "".join(
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text"
        ).strip()
        if text:
            return text
    return None


async def run(uri, token, executor):
    async with websockets.connect(uri) as ws:
        await ws.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "hello",
                    "token": token,
                    "client": {"name": "pi-remote-session-test"},
                }
            )
        )
        await recv_kind(ws, "welcome")

        create = {
            "v": 1,
            "kind": "create_session",
            "name": "remote-test",
            "model": "mock-model",
        }
        if executor:
            create["executor"] = executor
        await ws.send(json.dumps(create))
        attached = await recv_kind(ws, "attached")
        session_id = attached.get("sessionId")
        if not session_id:
            fail(f"attached envelope missing sessionId: {attached}")

        await ws.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "command",
                    "sessionId": session_id,
                    "payload": {
                        "type": "prompt",
                        "message": "hi",
                        "streamingBehavior": "steer",
                    },
                }
            )
        )

        deltas = []
        final_text = None
        while True:
            raw = await asyncio.wait_for(ws.recv(), timeout=RECV_TIMEOUT_S)
            msg = json.loads(raw)
            if msg.get("kind") == "error":
                fail(f"server error during turn: {msg}")
            if msg.get("kind") != "event":
                continue
            if msg.get("sessionId") != session_id:
                fail(f"event for unexpected session {msg.get('sessionId')!r}")
            ev = msg.get("payload") or {}
            etype = ev.get("type")
            if etype == "message_update":
                me = ev.get("assistantMessageEvent") or {}
                if me.get("type") == "text_delta":
                    deltas.append(me.get("delta") or "")
            elif etype == "agent_end":
                final_text = agent_end_text(ev)
                break

        if len(deltas) < 2:
            fail(f"expected >=2 text_delta events, got {len(deltas)}")
        joined = "".join(deltas).strip()
        if EXPECTED_REPLY not in joined and joined != EXPECTED_REPLY:
            fail(f"streamed text {joined!r} did not match {EXPECTED_REPLY!r}")
        if (
            final_text
            and EXPECTED_REPLY not in final_text
            and final_text != EXPECTED_REPLY
        ):
            fail(f"agent_end text {final_text!r} did not match {EXPECTED_REPLY!r}")
        print("OK")


def main():
    if len(sys.argv) < 3:
        fail("usage: driver.py <ws_url> <token> [executor-id]")
    uri = sys.argv[1]
    token = sys.argv[2]
    executor = sys.argv[3] if len(sys.argv) > 3 else None
    try:
        asyncio.run(run(uri, token, executor))
    except websockets.exceptions.WebSocketException as e:
        fail(f"websocket error: {e!r}")
    except asyncio.TimeoutError:
        fail("timed out waiting for a server envelope")
    except OSError as e:
        fail(f"could not reach server: {e!r}")


if __name__ == "__main__":
    main()
