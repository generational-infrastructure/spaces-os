#!/usr/bin/env python3
"""Scripted daemon for the create-ack routing contract.

create_session's ack carries no correlation id, so the panel resolves
pending creates FIFO. A plain attach ack (re-attach of a persisted
session) racing an in-flight create must NOT consume the create's
resolver — pre-fix it did, stamping the attached session's id onto the
creating entry (two panel tabs sharing one daemon session, the real
create's ack resolving nothing).

This daemon forces the interleave deterministically: the attach ack
for the persisted session is WITHHELD until a create_session arrives,
then sent first, followed by the create ack. The panel must still
route each ack to the right requester via the `created` flag.
"""

import asyncio
import json
import sys
import time

import websockets

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8781
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""

PERSISTED_SID = "sess-persisted"


def now_ms() -> int:
    return int(time.time() * 1000)


async def handle(ws):
    pending_attach = None  # withheld attach ack envelope
    created = 0

    async def send(obj):
        await ws.send(json.dumps(obj))

    async for raw in ws:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        kind = msg.get("kind")
        print(f"recv {kind} {msg.get('sessionId', '')}", file=sys.stderr, flush=True)

        if kind == "hello":
            if TOKEN and msg.get("token") != TOKEN:
                await send({"v": 1, "kind": "error", "error": "unauthorized"})
                await ws.close()
                return
            await send(
                {
                    "v": 1,
                    "kind": "welcome",
                    "connectionId": "c1",
                    "caps": {"executor": "host"},
                }
            )

        elif kind == "list_sessions":
            await send(
                {
                    "v": 1,
                    "kind": "sessions",
                    "sessions": [
                        {
                            "id": PERSISTED_SID,
                            "name": "Chat 1",
                            "executor": "host",
                            "state": "cold",
                            "updated": now_ms(),
                        }
                    ],
                }
            )

        elif kind == "attach":
            # Withhold the ack: it is released the moment a create lands,
            # ORDERED BEFORE the create ack — the racing interleave.
            pending_attach = {
                "v": 1,
                "kind": "attached",
                "sessionId": msg.get("sessionId"),
                "seq": 0,
            }

        elif kind == "create_session":
            created += 1
            if pending_attach is not None:
                await send(pending_attach)
                pending_attach = None
            await send(
                {
                    "v": 1,
                    "kind": "attached",
                    "sessionId": f"sess-created-{created}",
                    "seq": 0,
                    "created": True,
                }
            )

        elif kind == "command":
            payload = msg.get("payload") or {}
            req_id = payload.get("id")
            ptype = payload.get("type")
            sid = msg.get("sessionId")
            if ptype == "get_available_models":
                await send(
                    {
                        "v": 1,
                        "kind": "event",
                        "sessionId": sid,
                        "seq": 1,
                        "payload": {
                            "type": "response",
                            "command": "get_available_models",
                            "success": True,
                            "id": req_id,
                            "data": {
                                "models": [{"provider": "local", "id": "mock-model"}]
                            },
                        },
                    }
                )


async def main():
    async with websockets.serve(handle, "127.0.0.1", PORT):
        print("READY", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
