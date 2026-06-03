#!/usr/bin/env python3
"""Minimal fake pi-sessiond for the panel multi-homing test.

Speaks just enough of the §12 protocol to let the real panel attach and drive
a session, replying with a fixed, per-executor marker so the test can prove a
session pinned to executor X actually streams from X (not Y or the local pi):

  hello           -> welcome
  create_session  -> attached {sessionId}
  attach          -> attached {sessionId}
  command{prompt} -> agent_start, text_start/delta/end, agent_end carrying REPLY

Usage: fake-daemon.py <port> <reply> [token]. Binds 127.0.0.1:<port>.
"""

import asyncio
import json
import sys

import websockets

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8770
REPLY = sys.argv[2] if len(sys.argv) > 2 else "Hello, world!"
TOKEN = sys.argv[3] if len(sys.argv) > 3 else ""


async def handler(ws, *_):
    seq = 0
    created = 0  # mint a distinct sessionId per create so the panel (which may
    #              open several sessions on one executor) never collides

    async def event(sid, payload):
        nonlocal seq
        seq += 1
        await ws.send(json.dumps(
            {"v": 1, "kind": "event", "sessionId": sid, "seq": seq, "payload": payload}))

    async for raw in ws:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        kind = msg.get("kind")

        if kind == "hello":
            if TOKEN and msg.get("token") != TOKEN:
                await ws.send(json.dumps({"v": 1, "kind": "error", "error": "unauthorized"}))
                await ws.close()
                return
            await ws.send(json.dumps({"v": 1, "kind": "welcome", "connectionId": "c1", "caps": {}}))
        elif kind == "create_session":
            created += 1
            await ws.send(json.dumps(
                {"v": 1, "kind": "attached", "sessionId": f"sess-{PORT}-{created}", "seq": 0}))
        elif kind == "attach":
            await ws.send(json.dumps(
                {"v": 1, "kind": "attached", "sessionId": msg.get("sessionId"), "seq": 0}))
        elif kind == "command":
            sid = msg.get("sessionId")
            if (msg.get("payload") or {}).get("type") != "prompt":
                continue
            await event(sid, {"type": "agent_start"})
            await event(sid, {"type": "message_update",
                              "assistantMessageEvent": {"type": "text_start", "contentIndex": 0}})
            await event(sid, {"type": "message_update",
                              "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": REPLY}})
            await event(sid, {"type": "message_update",
                              "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": REPLY}})
            await event(sid, {"type": "agent_end",
                              "messages": [{"role": "assistant", "content": [{"type": "text", "text": REPLY}]}]})


async def main():
    async with websockets.serve(handler, "127.0.0.1", PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
