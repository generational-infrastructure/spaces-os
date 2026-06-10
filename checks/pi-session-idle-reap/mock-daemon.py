#!/usr/bin/env python3
"""Mock pi-sessiond for the WS-era idle-reap contract test.

Speaks enough of the §12 protocol for PiChatBackend to create and drive
sessions over a single executor WebSocket:

  hello           -> welcome {caps:{executor: <id>}}
  list_sessions   -> sessions [ current list ]
  create_session  -> attached {sessionId} + sessions broadcast
  attach          -> attached {sessionId}
  detach          -> recorded only (no ack — the panel doesn't await one)
  delete_session  -> drop + sessions broadcast
  command{prompt} -> agent_start, text stream, then:
                       * prompt contains "HOLD": NO agent_end — the turn
                         stays in flight forever, so the panel keeps
                         busy=true (the un-reapable session).
                       * otherwise: agent_end carrying REPLY — the turn
                         completes, busy clears, and the session becomes
                         idle-but-streaming (the reapable one).
  command{set_memory} -> tolerated (recorded, no reply). The panel sends
                         it as the first command after every create/attach.

Every parsed inbound frame is appended as a JSON line to the file named
by argv[3] (the frame log). The driver asserts the reaper contract off
this log: a `detach` frame must arrive for the idle session's daemon id
and must NOT arrive for the busy one.

Usage: mock-daemon.py [executor_id] [token] [frame_log]. Binds an
ephemeral 127.0.0.1 port and prints `ws://127.0.0.1:<port>` on stdout so
the driver can discover it.
"""

import asyncio
import json
import sys
import time

import websockets

EXEC_ID = sys.argv[1] if len(sys.argv) > 1 else "remote"
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""
FRAME_LOG = sys.argv[3] if len(sys.argv) > 3 else ""

REPLY = "Background task complete"

# id -> {name, updated}
sessions: dict[str, dict] = {}
_created = 0


def now_ms() -> int:
    return int(time.time() * 1000)


def log_frame(msg: dict) -> None:
    if not FRAME_LOG:
        return
    with open(FRAME_LOG, "a") as fh:
        fh.write(json.dumps(msg) + "\n")
        fh.flush()


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
        log_frame(msg)
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
            await send({"v": 1, "kind": "attached", "sessionId": sid, "seq": 0})
            await broadcast_sessions()

        elif kind == "attach":
            sid = msg.get("sessionId")
            await send({"v": 1, "kind": "attached", "sessionId": sid, "seq": 0})

        elif kind == "detach":
            # The reaper's whole observable effect: PiSession.stop() emits
            # this frame (plus a panel-local unsubscribe). Recorded by
            # log_frame above; nothing to send back.
            pass

        elif kind == "delete_session":
            sid = msg.get("sessionId")
            sessions.pop(sid, None)
            await broadcast_sessions()

        elif kind == "command":
            sid = msg.get("sessionId")
            payload = msg.get("payload") or {}
            # set_memory (and anything else non-prompt) is tolerated: the
            # panel fires it unconditionally after create/attach.
            if payload.get("type") != "prompt":
                continue
            if sid in sessions:
                sessions[sid]["updated"] = now_ms()
            hold = "HOLD" in (payload.get("message") or "")
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
            if hold:
                # Held turn: never finish — no text_end, no agent_end. The
                # panel keeps busy=true and the reaper must skip it.
                continue
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
