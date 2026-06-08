#!/usr/bin/env python3
"""Fake pi-sessiond that drops the FIRST create_session, accepts the retry.

Reproduces the boot-time connection flap the real daemon exhibits while it
is still coming up: the panel's first create_session never gets its
`attached` ack because the link drops mid-create. A correct client retries
the create on the next welcome; a client that treated the first spawn as the
only attempt would leave the prompt buffered forever.

  hello                  -> welcome
  create_session (#1)    -> CLOSE the socket (no ack) — the flap
  create_session (#2..)  -> attached {sessionId}
  attach                 -> attached {sessionId}
  command{prompt}        -> agent_start, text stream, agent_end carrying REPLY

State (the "have we dropped once yet" flag) is process-global so it survives
the client's reconnect. Usage: fake-daemon.py <port> [token].
"""

import asyncio
import json
import sys

import websockets

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8780
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""

REPLY = "Reply after the retried create"
_dropped_once = False
_created = 0


async def handler(ws, *_):
    global _dropped_once, _created
    seq = 0

    async def event(sid, payload):
        nonlocal seq
        seq += 1
        await ws.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "event",
                    "sessionId": sid,
                    "seq": seq,
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
            if not _dropped_once:
                # The flap: drop the link mid-create, before any ack.
                _dropped_once = True
                await ws.close()
                return
            _created += 1
            await ws.send(
                json.dumps(
                    {
                        "v": 1,
                        "kind": "attached",
                        "sessionId": f"sess-{_created}",
                        "seq": 0,
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
            if (msg.get("payload") or {}).get("type") != "prompt":
                continue
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
    async with websockets.serve(handler, "127.0.0.1", PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
