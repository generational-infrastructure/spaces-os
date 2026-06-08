#!/usr/bin/env python3
"""Fake pi-sessiond for the quick-launch duplicate-session regression.

Speaks enough of the §12 protocol to reproduce the create→broadcast→re-import
race the real daemon (packages/pi-sessiond/main.ts) triggers on create_session:

  hello           -> welcome {caps:{executor: <id>}}
  list_sessions   -> sessions [ current list ]
  create_session  -> attached {sessionId}      (the create ack, FIFO)
                     sessions  [ current list ] (unsolicited broadcast,
                                                  sent IMMEDIATELY after the
                                                  ack — same as main.ts's
                                                  send(attached); broadcastSessionsList())
  attach          -> attached {sessionId}
  command{prompt} -> agent_start, text stream, agent_end carrying REPLY
  delete_session  -> drop + sessions broadcast

The `attached`-then-`sessions` pair is sent back-to-back, mirroring main.ts's
create_session handler (send(attached); broadcastSessionsList()): every
just-minted id is advertised to the panel's importer immediately, so the
orphan id of a doubled create re-imports as a duplicate right away.

Usage: mock-daemon.py [executor_id] [token]. Binds an ephemeral 127.0.0.1
port and prints `ws://127.0.0.1:<port>` on stdout so the driver can discover
it.
"""

import asyncio
import json
import sys
import time

import websockets

EXEC_ID = sys.argv[1] if len(sys.argv) > 1 else "remote"
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""

REPLY = "Hello from the remote executor"

# id -> {name, updated}
sessions: dict[str, dict] = {}
_created = 0


def now_ms() -> int:
    return int(time.time() * 1000)


def sessions_payload() -> list[dict]:
    return [
        {
            "id": sid,
            "name": meta["name"],
            "executor": EXEC_ID,
            "state": "live-idle",
            "updated": meta["updated"],
        }
        for sid, meta in sessions.items()
    ]


async def handler(ws, *_):
    seq = 0

    async def send(obj):
        await ws.send(json.dumps(obj))

    async def broadcast_sessions():
        await send({"v": 1, "kind": "sessions", "sessions": sessions_payload()})

    async def event(sid, payload):
        nonlocal seq
        seq += 1
        await send(
            {"v": 1, "kind": "event", "sessionId": sid, "seq": seq, "payload": payload}
        )

    async for raw in ws:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        kind = msg.get("kind")

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
                    "caps": {"executor": EXEC_ID},
                }
            )

        elif kind == "list_sessions":
            await broadcast_sessions()

        elif kind == "create_session":
            global _created
            _created += 1
            sid = f"sess-{EXEC_ID}-{_created}"
            sessions[sid] = {"name": msg.get("name") or "", "updated": now_ms()}
            # The create ack, then the list broadcast — back-to-back,
            # mirroring main.ts's create_session handler exactly.
            await send({"v": 1, "kind": "attached", "sessionId": sid, "seq": 0})
            await broadcast_sessions()

        elif kind == "attach":
            sid = msg.get("sessionId")
            await send({"v": 1, "kind": "attached", "sessionId": sid, "seq": 0})

        elif kind == "delete_session":
            sid = msg.get("sessionId")
            sessions.pop(sid, None)
            await broadcast_sessions()

        elif kind == "command":
            sid = msg.get("sessionId")
            payload = msg.get("payload") or {}
            if payload.get("type") != "prompt":
                continue
            if sid in sessions:
                sessions[sid]["updated"] = now_ms()
            await event(sid, {"type": "agent_start"})
            await event(
                sid,
                {
                    "type": "message_update",
                    "assistantMessageEvent": {"type": "text_start", "contentIndex": 0},
                },
            )
            await event(
                sid,
                {
                    "type": "message_update",
                    "assistantMessageEvent": {
                        "type": "text_delta",
                        "contentIndex": 0,
                        "delta": REPLY,
                    },
                },
            )
            await event(
                sid,
                {
                    "type": "message_update",
                    "assistantMessageEvent": {
                        "type": "text_end",
                        "contentIndex": 0,
                        "content": REPLY,
                    },
                },
            )
            await event(
                sid,
                {
                    "type": "agent_end",
                    "messages": [
                        {
                            "role": "assistant",
                            "content": [{"type": "text", "text": REPLY}],
                        }
                    ],
                },
            )


async def main():
    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        sys.stdout.write(f"ws://127.0.0.1:{port}\n")
        sys.stdout.flush()
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
