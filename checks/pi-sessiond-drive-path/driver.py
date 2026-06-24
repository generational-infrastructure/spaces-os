#!/usr/bin/env python3
"""Daemon-level drive-path check (runtime-isolation refactor §9 step 1).

Boots the real pi-sessiond supervisor pointed at a stub pi child
(SPACES_SESSIOND_PI_BIN) and asserts, over the §12 WebSocket envelope
protocol, that the supervisor drives the child correctly:

  1. create_session spawns a child; a plain prompt round-trips the child's
     event stream (agent_start … assistant text … agent_end) back to the
     client.
  2. an approval prompt surfaces the child's extension_ui_request as an event,
     and the client's extension_ui_response is relayed to the child, which
     unparks and finishes — proving the side-channel crosses the rpc pipe in
     both directions.

Real daemon + stub pi. No model, no network, no VM. ~3s.
"""

import asyncio
import json
import os
import socket
import subprocess
import sys
import time

import websockets

PORT = 8781


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


async def recv_event(ws, pred, what, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
        if m.get("kind") == "event" and pred(m.get("payload", {})):
            return m["payload"]
    fail(f"never saw {what}")


async def scenario(ws):
    await ws.send(json.dumps({"v": 1, "kind": "hello"}))
    if json.loads(await ws.recv()).get("kind") != "welcome":
        fail("hello did not yield welcome")

    await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": "drive"}))
    sid = None
    while True:
        m = json.loads(await ws.recv())
        if m.get("kind") == "attached" and m.get("created"):
            sid = m["sessionId"]
            break
        if m.get("kind") == "error":
            fail(f"create_session: {m}")

    async def command(payload):
        await ws.send(
            json.dumps(
                {"v": 1, "kind": "command", "sessionId": sid, "payload": payload}
            )
        )

    # 1. plain prompt: full turn streams back
    await command({"type": "prompt", "message": "hello"})
    await recv_event(ws, lambda p: p.get("type") == "agent_start", "agent_start")
    await recv_event(
        ws,
        lambda p: (
            p.get("type") == "assistant_message"
            and "stub reply: hello" in p.get("text", "")
        ),
        "assistant reply text",
    )
    await recv_event(ws, lambda p: p.get("type") == "agent_end", "agent_end")

    # 2. approval prompt: side-channel surfaces and resolves
    await command({"type": "prompt", "message": "CONFIRM this"})
    req = await recv_event(
        ws,
        lambda p: (
            p.get("type") == "extension_ui_request" and p.get("method") == "confirm"
        ),
        "extension_ui_request",
    )
    await command({"type": "extension_ui_response", "id": req["id"], "confirmed": True})
    await recv_event(
        ws,
        lambda p: (
            p.get("type") == "assistant_message"
            and "confirmed=True" in p.get("text", "")
        ),
        "post-approval reply",
    )
    await recv_event(
        ws, lambda p: p.get("type") == "agent_end", "agent_end after approval"
    )
    print(
        "PASS: supervisor drives the child end-to-end (turn + side-channel)", flush=True
    )


def wait_port(port, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.1)
    return False


def main():
    daemon_bin, stub_pi, systemd_run = sys.argv[1], sys.argv[2], sys.argv[3]
    state = os.path.join(os.environ["TMPDIR"], "state")
    os.makedirs(state, exist_ok=True)
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(PORT),
            "SPACES_SESSIOND_PI_BIN": stub_pi,
            # Single-mode: the daemon always wraps the child in systemd-run; in
            # the build sandbox there is no systemd, so point it at the
            # passthrough stub (strips the unit flags, applies --setenv, execs).
            "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
            "SPACES_SESSIOND_STATE_DIR": state,
        }
    )
    log = open(os.path.join(state, "daemon.log"), "w")
    proc = subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_port(PORT):
            fail(f"daemon never listened (exit={proc.poll()})")
        asyncio.run(asyncio.wait_for(_run(), timeout=30))
    finally:
        proc.terminate()
        with open(os.path.join(state, "daemon.log")) as f:
            sys.stderr.write("=== daemon log ===\n" + f.read())


async def _run():
    async with websockets.connect(f"ws://127.0.0.1:{PORT}") as ws:
        await scenario(ws)


if __name__ == "__main__":
    main()
