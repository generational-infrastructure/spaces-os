#!/usr/bin/env python3
"""Drive the integration file-exchange e2e against the REAL pi-sessiond over WS.

Opens a session and prompts the (mock-LLM-backed) real pi to run the github
integration demo, auto-approving each confirm-gated integration tool the
gateway raises. get_repo is autoRun and must NOT raise an approval;
clone_to_workspace and open_pull_request must. Prints the session id and the
tools that required approval so the test can assert the gateway gated the
effects and the round-trip completed.

usage: ws-drive.py <ws_url> <token> <prompt>
"""

import asyncio
import json
import sys
import time

import websockets

TURN_TIMEOUT_S = 240


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


async def recv_kind(ws, want, timeout=60):
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail(f"timed out awaiting {want!r}")
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
        if msg.get("kind") == want:
            return msg
        if msg.get("kind") == "error":
            fail(f"server error awaiting {want!r}: {msg}")


def cmd(sid, payload):
    return json.dumps({"v": 1, "kind": "command", "sessionId": sid, "payload": payload})


async def main():
    ws_url, token, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
    async with websockets.connect(ws_url) as ws:
        await ws.send(
            json.dumps(
                {"v": 1, "kind": "hello", "token": token, "client": {"name": "poc"}}
            )
        )
        await recv_kind(ws, "welcome")
        await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": "poc"}))
        sid = (await recv_kind(ws, "attached"))["sessionId"]
        await ws.send(cmd(sid, {"type": "prompt", "message": prompt}))

        approved = []
        deadline = time.monotonic() + TURN_TIMEOUT_S
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("timed out mid-turn")
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
            if msg.get("kind") != "event":
                continue
            p = msg.get("payload") or {}
            t = p.get("type")
            if t == "approval_request":
                approved.append(
                    p.get("toolName") or f"{p.get('integration')}_{p.get('tool')}"
                )
                await ws.send(
                    cmd(
                        sid,
                        {
                            "type": "approval_response",
                            "id": p["id"],
                            "decision": "once",
                        },
                    )
                )
            elif t == "agent_end":
                break

        print(f"SESSION_ID={sid}")
        print(f"APPROVED={json.dumps(approved)}")
        print("OK")


if __name__ == "__main__":
    asyncio.run(main())
