#!/usr/bin/env python3
"""Fake pi-sessiond for the headless WS transport check.

Speaks just enough of the §12 envelope protocol to exercise the panel's
WebSocket transport (PiExecutor + PiSession) without a real daemon, pi, or
LLM:

  hello          -> welcome
  create_session -> attached {sessionId}
  command{prompt}-> a stream of event{payload: pi event} envelopes carrying
                    text_delta deltas that concatenate to "Hello, world!",
                    terminated by agent_end.

The payloads are pi's real stdout event shapes (captured from a live run), so
they drive PiSession._handleMessageUpdate exactly as the daemon's forwarded
events would. Binds 127.0.0.1:<argv[1]>.
"""

import asyncio
import json
import sys

import websockets

CHUNKS = ["Hello", ", ", "world", "!"]
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""


async def handler(ws, *_):
    seq = 0

    async def event(sid, payload):
        nonlocal seq
        seq += 1
        await ws.send(
            json.dumps({"v": 1, "kind": "event", "sessionId": sid, "seq": seq, "payload": payload})
        )

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
            await ws.send(
                json.dumps({"v": 1, "kind": "welcome", "connectionId": "c1", "caps": {}})
            )
        elif kind == "create_session":
            await ws.send(
                json.dumps({"v": 1, "kind": "attached", "sessionId": "s1", "seq": 0})
            )
        elif kind == "command":
            sid = msg.get("sessionId")
            payload = msg.get("payload") or {}
            if payload.get("type") != "prompt":
                continue
            await event(sid, {"type": "agent_start"})
            await event(sid, {"type": "message_update",
                              "assistantMessageEvent": {"type": "text_start", "contentIndex": 0}})
            acc = ""
            for c in CHUNKS:
                acc += c
                await event(sid, {"type": "message_update",
                                  "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": c}})
                await asyncio.sleep(0.02)
            await event(sid, {"type": "message_update",
                              "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": acc}})
            await event(sid, {"type": "agent_end",
                              "messages": [{"role": "assistant",
                                            "content": [{"type": "text", "text": acc}]}]})


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8771
    async with websockets.serve(handler, "127.0.0.1", port):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
