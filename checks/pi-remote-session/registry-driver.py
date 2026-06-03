#!/usr/bin/env python3
"""Registry / mirroring driver for pi-sessiond (design §12 `sessions` + n:m).

Modes (all target a remote executor over the WebSocket envelope protocol):

    registry-driver.py mirror <ws_url> <token>
        Two clients attach the *same* session; one drives a turn; assert BOTH
        receive the streamed reply (multi-client fan-out / mirroring).

    registry-driver.py list <ws_url> <token>
        Print the `sessions` registry as a JSON array (the test asserts on it).

    registry-driver.py expect-cold <ws_url> <token> <sessionId>
        Exit 0 iff <sessionId> is in the registry with state "cold" (poll-able
        via wait_until_succeeds; tolerates the exit-reap delay after a kill).

Prints OK and exits 0 on success; FAIL: <reason> to stderr + exit 1 otherwise.
"""

import asyncio
import json
import sys

import websockets

EXPECTED_REPLY = "Hello, world!"
RECV_TIMEOUT_S = 60


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


async def recv_kind(ws, want):
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=RECV_TIMEOUT_S))
        if msg.get("kind") == want:
            return msg
        if msg.get("kind") == "error":
            fail(f"server error while awaiting {want!r}: {msg}")


async def hello(ws, token, name):
    await ws.send(
        json.dumps(
            {"v": 1, "kind": "hello", "token": token, "client": {"name": name}}
        )
    )
    await recv_kind(ws, "welcome")


async def collect_reply(ws, sid):
    """Drain events for `sid` until agent_end; return the concatenated text."""
    deltas = []
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=RECV_TIMEOUT_S))
        if msg.get("kind") != "event" or msg.get("sessionId") != sid:
            continue
        ev = msg.get("payload") or {}
        if ev.get("type") == "message_update":
            me = ev.get("assistantMessageEvent") or {}
            if me.get("type") == "text_delta":
                deltas.append(me.get("delta") or "")
        elif ev.get("type") == "agent_end":
            return "".join(deltas).strip()


async def run_mirror(uri, token):
    async with websockets.connect(uri) as a, websockets.connect(uri) as b:
        await hello(a, token, "mirror-a")
        await hello(b, token, "mirror-b")

        await a.send(
            json.dumps(
                {"v": 1, "kind": "create_session", "name": "mirror", "model": "mock-model"}
            )
        )
        sid = (await recv_kind(a, "attached")).get("sessionId")
        if not sid:
            fail("create_session returned no sessionId")

        # Second client mirrors the same session.
        await b.send(json.dumps({"v": 1, "kind": "attach", "sessionId": sid}))
        await recv_kind(b, "attached")

        # One client drives a turn; BOTH must receive the streamed reply.
        await a.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "command",
                    "sessionId": sid,
                    "payload": {
                        "type": "prompt",
                        "message": "hi",
                        "streamingBehavior": "steer",
                    },
                }
            )
        )
        reply_a, reply_b = await asyncio.gather(
            collect_reply(a, sid), collect_reply(b, sid)
        )
        if EXPECTED_REPLY not in reply_a:
            fail(f"client A reply {reply_a!r} missing {EXPECTED_REPLY!r}")
        if EXPECTED_REPLY not in reply_b:
            fail(f"client B mirror {reply_b!r} missing {EXPECTED_REPLY!r}")
        print("OK")


async def fetch_sessions(uri, token):
    async with websockets.connect(uri) as ws:
        await hello(ws, token, "registry")
        await ws.send(json.dumps({"v": 1, "kind": "list_sessions"}))
        msg = await recv_kind(ws, "sessions")
        return msg.get("sessions") or []


async def run_list(uri, token):
    print(json.dumps(await fetch_sessions(uri, token)))


async def run_expect_cold(uri, token, sid):
    for s in await fetch_sessions(uri, token):
        if s.get("id") == sid:
            if s.get("state") == "cold":
                print("OK")
                return
            fail(f"session {sid} state is {s.get('state')!r}, not cold")
    fail(f"session {sid} not in the registry")


def main():
    args = sys.argv[1:]
    if len(args) < 3:
        fail("usage: registry-driver.py <mirror|list|expect-cold> <ws_url> <token> [sessionId]")
    mode, uri, token = args[0], args[1], args[2]
    if mode == "mirror":
        coro = run_mirror(uri, token)
    elif mode == "list":
        coro = run_list(uri, token)
    elif mode == "expect-cold":
        if len(args) < 4:
            fail("expect-cold needs a sessionId")
        coro = run_expect_cold(uri, token, args[3])
    else:
        fail(f"unknown mode: {mode}")
    try:
        asyncio.run(coro)
    except websockets.exceptions.WebSocketException as e:
        fail(f"websocket error: {e!r}")
    except asyncio.TimeoutError:
        fail("timed out waiting for a server envelope")
    except OSError as e:
        fail(f"could not reach server: {e!r}")


if __name__ == "__main__":
    main()
