#!/usr/bin/env python3
"""Daemon-level side-channel test (design §6), against the REAL pi-sessiond.

Boots the daemon with a fake pi (no VM, no LLM) behind a systemd-run stub and
drives two scenarios over the §12 WebSocket protocol:

  1. first-answer-wins — two clients mirror one session and both answer the same
     extension_ui_request; pi must receive exactly ONE response (confirm_received
     n==1, never 2), and the loser must get a `sidechannel_resolved`.
  2. park — a zero-client extension_ui_request marks the session `parked`
     (visible via list_sessions), survives, and is resolvable on re-attach.

Usage: driver.py <daemon_bin> <fake_pi> <systemd_run_stub>
"""

import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

import websockets

TOKEN = "sidechannel-secret"
PORT = 8771


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def uri():
    return f"ws://127.0.0.1:{PORT}"


async def recv_kind(ws, want, timeout=30):
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
        if msg.get("kind") == want:
            return msg
        if msg.get("kind") == "error":
            fail(f"server error while awaiting {want!r}: {msg}")


async def hello(ws, name):
    await ws.send(
        json.dumps({"v": 1, "kind": "hello", "token": TOKEN, "client": {"name": name}})
    )
    await recv_kind(ws, "welcome")


async def drain_for(ws, pred, timeout=30):
    """Return the first event payload matching pred(payload), or None on timeout."""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
        except asyncio.TimeoutError:
            return None
        if msg.get("kind") == "event" and pred(msg.get("payload") or {}):
            return msg.get("payload") or {}


async def collect_all(ws, idle=1.5, timeout=10):
    """Collect every envelope until `idle` seconds pass with none (or timeout)."""
    out = []
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=idle))
        except asyncio.TimeoutError:
            break
        out.append(msg)
    return out


def cmd(sid, payload):
    return json.dumps({"v": 1, "kind": "command", "sessionId": sid, "payload": payload})


async def scenario_first_answer_wins():
    async with websockets.connect(uri()) as a, websockets.connect(uri()) as b:
        await hello(a, "a")
        await hello(b, "b")

        await a.send(json.dumps({"v": 1, "kind": "create_session", "name": "sc"}))
        sid = (await recv_kind(a, "attached"))["sessionId"]
        await b.send(json.dumps({"v": 1, "kind": "attach", "sessionId": sid}))
        await recv_kind(b, "attached")

        await a.send(cmd(sid, {"type": "prompt", "message": "go"}))

        # Both mirrored clients must see the side-channel request.
        req_a = await drain_for(a, lambda e: e.get("type") == "extension_ui_request")
        req_b = await drain_for(b, lambda e: e.get("type") == "extension_ui_request")
        if not req_a or not req_b:
            fail(f"both clients should see the request (a={req_a!r}, b={req_b!r})")
        rid = req_a["id"]

        # Both answer the same id. First wins; the other is dropped + told resolved.
        await a.send(cmd(sid, {"type": "extension_ui_response", "id": rid, "confirmed": True}))
        await b.send(cmd(sid, {"type": "extension_ui_response", "id": rid, "confirmed": False}))

        msgs_a, msgs_b = await asyncio.gather(collect_all(a), collect_all(b))

        def confirm_ns(msgs):
            return [
                m["payload"].get("n")
                for m in msgs
                if m.get("kind") == "event"
                and (m.get("payload") or {}).get("type") == "confirm_received"
            ]

        ns = confirm_ns(msgs_a) + confirm_ns(msgs_b)
        if any(n and n >= 2 for n in ns):
            fail(f"pi received more than one response (confirm_received n>=2): {ns}")
        if 1 not in ns:
            fail(f"pi never received the winning response (no confirm_received n==1): {ns}")

        def resolved_count(msgs):
            return sum(1 for m in msgs if m.get("kind") == "sidechannel_resolved")

        ra, rb = resolved_count(msgs_a), resolved_count(msgs_b)
        # Exactly one side (the loser) must be told to collapse; the winner none.
        if not ((ra == 0 and rb >= 1) or (rb == 0 and ra >= 1)):
            fail(f"sidechannel_resolved should reach only the loser (a={ra}, b={rb})")

        # The turn must complete exactly once.
        ends = sum(
            1
            for m in msgs_a + msgs_b
            if m.get("kind") == "event" and (m.get("payload") or {}).get("type") == "agent_end"
        )
        if ends < 1:
            fail("turn never reached agent_end")


async def session_state(sid):
    async with websockets.connect(uri()) as ws:
        await hello(ws, "lister")
        await ws.send(json.dumps({"v": 1, "kind": "list_sessions"}))
        for s in (await recv_kind(ws, "sessions")).get("sessions") or []:
            if s.get("id") == sid:
                return s.get("state")
    return None


async def wait_state(sid, want, timeout=10):
    deadline = time.monotonic() + timeout
    st = None
    while time.monotonic() < deadline:
        st = await session_state(sid)
        ok = want(st) if callable(want) else (st == want)
        if ok:
            return st
        await asyncio.sleep(0.2)
    fail(f"session {sid} state never satisfied (last={st!r})")


async def scenario_park():
    async with websockets.connect(uri()) as a:
        await hello(a, "a")
        await a.send(json.dumps({"v": 1, "kind": "create_session", "name": "park"}))
        sid = (await recv_kind(a, "attached"))["sessionId"]

        # Detach BEFORE prompting (ordered on one conn) so the request fires
        # with zero clients attached and the session parks.
        await a.send(json.dumps({"v": 1, "kind": "detach", "sessionId": sid}))
        await a.send(cmd(sid, {"type": "prompt", "message": "go"}))
        await wait_state(sid, "parked")

        # Re-attach: the buffered request replays; answering it unparks the session.
        await a.send(json.dumps({"v": 1, "kind": "attach", "sessionId": sid, "lastSeq": 0}))
        await recv_kind(a, "attached")
        req = await drain_for(a, lambda e: e.get("type") == "extension_ui_request")
        if not req:
            fail("re-attach did not replay the parked request")
        await a.send(cmd(sid, {"type": "extension_ui_response", "id": req["id"], "confirmed": True}))
        await drain_for(a, lambda e: e.get("type") == "agent_end")
        await wait_state(sid, lambda st: st is not None and st != "parked")


async def run_all():
    await scenario_first_answer_wins()
    await scenario_park()


def wait_port(port, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    fail(f"daemon never opened port {port}")


def main():
    if len(sys.argv) < 4:
        fail("usage: driver.py <daemon_bin> <fake_pi> <systemd_run_stub>")
    daemon_bin, fake_pi, stub = sys.argv[1], sys.argv[2], sys.argv[3]

    state = tempfile.mkdtemp(prefix="sessiond-")
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(PORT),
            "SPACES_SESSIOND_TOKEN": TOKEN,
            "PI_BIN": fake_pi,
            "SPACES_SESSIOND_SYSTEMD_RUN": stub,
            "SPACES_SESSIOND_STATE_DIR": state,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",  # disable idle-GC for determinism
            "HOME": state,
        }
    )
    log_path = os.path.join(state, "daemon.log")
    log = open(log_path, "wb")
    proc = subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        wait_port(PORT)
        asyncio.run(run_all())
        print("OK")
    except SystemExit:
        log.flush()
        with open(log_path) as fh:
            sys.stderr.write("=== daemon log ===\n" + fh.read())
        raise
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
