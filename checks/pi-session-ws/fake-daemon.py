#!/usr/bin/env python3
"""Fake pi-sessiond for the headless WS transport check.

Speaks just enough of the §12 envelope protocol to exercise the panel's
WebSocket transport (PiExecutor + PiSession) without a real daemon, pi, or
LLM — including reconnect-with-history:

  hello          -> welcome
  create_session -> attached {sessionId, seq:0}
  command{prompt}-> a stream of event{payload: pi event} envelopes carrying
                    text_delta deltas that concatenate to "Hello, world!"
                    (terminated by agent_end). Each event is also buffered with
                    a monotonic seq. Then a SECOND turn ("Caught up!") is
                    buffered but NOT sent, and the connection is dropped — as if
                    a turn streamed while the client was away.
  attach {lastSeq} (on the reconnect) -> replay every buffered event with
                    seq > lastSeq, so the panel catches up to the turn it
                    missed (design §5: warm reconnect).

Per-session state (seq + full event buffer) lives module-level so it survives
across the dropped/reconnected connections. Binds 127.0.0.1:<argv[1]>.
"""

import asyncio
import json
import sys

import websockets

CHUNKS = ["Hello", ", ", "world", "!"]      # turn 1 (streamed live)
CATCHUP = ["Caught", " up", "!"]            # turn 2 (missed; replayed on reattach)
TOKEN = sys.argv[2] if len(sys.argv) > 2 else ""

# sid -> {"seq": int, "buffer": [(seq, payload)]}, persisted across connections.
SESSIONS = {}


def turn_events(chunks):
    yield {"type": "agent_start"}
    yield {"type": "message_update",
           "assistantMessageEvent": {"type": "text_start", "contentIndex": 0}}
    acc = ""
    for c in chunks:
        acc += c
        yield {"type": "message_update",
               "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": c}}
    yield {"type": "message_update",
           "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": acc}}
    yield {"type": "agent_end",
           "messages": [{"role": "assistant", "content": [{"type": "text", "text": acc}]}]}


async def handler(ws, *_):
    async def send_event(sid, seq, payload):
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
            await ws.send(json.dumps(
                {"v": 1, "kind": "welcome", "connectionId": "c1", "caps": {}}))

        elif kind == "create_session":
            SESSIONS["s1"] = {"seq": 0, "buffer": []}
            await ws.send(json.dumps(
                {"v": 1, "kind": "attached", "sessionId": "s1", "seq": 0}))

        elif kind == "attach":
            sid = msg.get("sessionId")
            last = msg.get("lastSeq") or 0
            st = SESSIONS.get(sid)
            await ws.send(json.dumps(
                {"v": 1, "kind": "attached", "sessionId": sid, "seq": st["seq"] if st else 0}))
            if st:
                for seq, payload in st["buffer"]:
                    if seq > last:
                        await send_event(sid, seq, payload)

        elif kind == "command":
            sid = msg.get("sessionId")
            payload = msg.get("payload") or {}
            if payload.get("type") != "prompt":
                continue
            message = payload.get("message") or ""
            # Side-channel: a prompt of "confirm" opens an extension_ui_request;
            # "resolve" then sends sidechannel_resolved (as if another mirrored
            # client answered first), which must collapse the panel's prompt.
            if message == "confirm":
                st = SESSIONS.setdefault(sid, {"seq": 0, "buffer": []})
                st["seq"] += 1
                await send_event(sid, st["seq"], {
                    "type": "extension_ui_request",
                    "id": "sc-1",
                    "method": "confirm",
                    "title": "Run it?",
                })
                continue
            if message == "resolve":
                await ws.send(json.dumps({
                    "v": 1,
                    "kind": "sidechannel_resolved",
                    "sessionId": sid,
                    "id": "sc-1",
                    "by": "other",
                }))
                continue
            st = SESSIONS.setdefault(sid, {"seq": 0, "buffer": []})
            # Turn 1: stream live + buffer.
            for ev in turn_events(CHUNKS):
                st["seq"] += 1
                st["buffer"].append((st["seq"], ev))
                await send_event(sid, st["seq"], ev)
                await asyncio.sleep(0.02)
            # Give the driver a beat to observe turn 1, then buffer a turn the
            # client will MISS and drop the connection. The panel must reconnect,
            # re-attach with lastSeq, and replay it.
            await asyncio.sleep(1.0)
            for ev in turn_events(CATCHUP):
                st["seq"] += 1
                st["buffer"].append((st["seq"], ev))
            await ws.close()
            return


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8771
    async with websockets.serve(handler, "127.0.0.1", port):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
