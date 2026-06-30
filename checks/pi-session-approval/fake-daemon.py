#!/usr/bin/env python3
"""Fake pi-sessiond/gateway for the integration-approval check.

Speaks just enough of the §12 envelope protocol to (1) attach a session and
(2) play the supervisor gateway:

  hello          -> welcome
  create_session -> attached {sessionId:"s1", seq:0}
  command{prompt:"approve:<id>"} -> emit one
        event{payload:{type:"approval_request", id:<id>, integration, tool,
        toolName, args}} — exactly the shape main.ts:raiseApproval broadcasts.
  command{payload:{type:"approval_response", id, decision}} -> the panel's
        reply. Appended (one JSON object per line) to the record file passed as
        argv[3], so the driver can assert the decision actually crossed the
        wire rather than only being patched into the local bubble.

Binds 127.0.0.1:<argv[1]>; token = argv[2]; record file = argv[3].
"""

import asyncio
import json
import sys

import websockets

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8772
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
RECORD = sys.argv[3] if len(sys.argv) > 3 else ""

SEQ = {"n": 0}


async def handler(ws, *_):
    async def send_event(sid, payload):
        SEQ["n"] += 1
        await ws.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "event",
                    "sessionId": sid,
                    "seq": SEQ["n"],
                    "payload": payload,
                }
            )
        )

    async for raw in ws:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        kind = msg.get("kind")

        if kind == "hello":
            if TOKEN and msg.get("token") != TOKEN:
                await ws.send(
                    json.dumps({"v": 1, "kind": "error", "error": "unauthorized"})
                )
                await ws.close()
                return
            await ws.send(
                json.dumps(
                    {"v": 1, "kind": "welcome", "connectionId": "c1", "caps": {}}
                )
            )

        elif kind == "create_session":
            await ws.send(
                json.dumps(
                    {
                        "v": 1,
                        "kind": "attached",
                        "sessionId": "s1",
                        "seq": 0,
                        "created": True,
                    }
                )
            )

        elif kind == "attach":
            await ws.send(
                json.dumps(
                    {
                        "v": 1,
                        "kind": "attached",
                        "sessionId": msg.get("sessionId"),
                        "seq": 0,
                    }
                )
            )

        elif kind == "command":
            sid = msg.get("sessionId")
            payload = msg.get("payload") or {}
            ptype = payload.get("type")
            if ptype == "prompt":
                message = payload.get("message") or ""
                if message.startswith("approve:"):
                    appr_id = message.split(":", 1)[1]
                    await send_event(
                        sid,
                        {
                            "type": "approval_request",
                            "id": appr_id,
                            "integration": "github",
                            "tool": "create_issue",
                            "toolName": "github_create_issue",
                            "args": {"repo": "octo/repo", "title": "hello"},
                        },
                    )
            elif ptype == "approval_response" and RECORD:
                with open(RECORD, "a") as fh:
                    fh.write(
                        json.dumps(
                            {
                                "id": payload.get("id"),
                                "decision": payload.get("decision"),
                            }
                        )
                        + "\n"
                    )


async def main():
    async with websockets.serve(handler, "127.0.0.1", PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
