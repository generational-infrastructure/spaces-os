#!/usr/bin/env python3
"""Mock pi-sessiond for the new-chat model-inheritance contract test.

Speaks enough of the §12 protocol for PiSession's WS lifecycle and keeps
an ordered witness of every frame (both directions) in a JSON-lines log
so the driver can assert the create_session envelope on the wire:

  hello           -> welcome {caps:{executor: <id>}}
  list_sessions   -> sessions [ current list ]
  create_session  -> attached {sessionId, created:true}  (the create ack)
                     sessions  [ current list ]  (broadcast, like main.ts)
  attach          -> attached {sessionId}
  detach          -> recorded only (no reply, like the real daemon)
  command         -> recorded; set_memory is tolerated (PiSession sends it
                     on every spawn); set_model is acked with an
                     event-envelope response echoing the request id.

Frame log lines are {"dir": "recv"|"send", "frame": <envelope>}, appended
in arrival/emission order and flushed per line.

Usage: mock-daemon.py <frames_log> [executor_id] [token]. Binds an
ephemeral 127.0.0.1 port and prints `ws://127.0.0.1:<port>` on stdout so
the driver can discover it.
"""

import asyncio
import json
import sys
import time

import websockets

FRAMES_LOG = sys.argv[1]
EXEC_ID = sys.argv[2] if len(sys.argv) > 2 else "remote"
TOKEN = sys.argv[3] if len(sys.argv) > 3 else ""

# id -> {name, updated}
sessions: dict[str, dict] = {}
_created = 0

_log = open(FRAMES_LOG, "a")


def witness(direction: str, frame: dict) -> None:
    _log.write(json.dumps({"dir": direction, "frame": frame}) + "\n")
    _log.flush()


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
        witness("send", obj)
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
        witness("recv", msg)
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
            # Create ack, then the list broadcast — back-to-back, mirroring
            # main.ts's create_session handler.
            await send(
                {
                    "v": 1,
                    "kind": "attached",
                    "sessionId": sid,
                    "seq": 0,
                    "created": True,
                }
            )
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
            ptype = payload.get("type")
            # set_memory arrives on every spawn — tolerate it: recorded
            # above, no reply needed.
            if ptype == "set_model":
                resp = {
                    "type": "response",
                    "command": "set_model",
                    "success": True,
                    "data": {
                        "provider": payload.get("provider"),
                        "id": payload.get("modelId"),
                    },
                }
                # Echo the request id so PiSession._request promises resolve.
                if payload.get("id"):
                    resp["id"] = payload["id"]
                await event(sid, resp)


async def main():
    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        sys.stdout.write(f"ws://127.0.0.1:{port}\n")
        sys.stdout.flush()
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
