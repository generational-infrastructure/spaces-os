#!/usr/bin/env python3
"""Daemon-level side-channel test (design §6), against the REAL pi-sessiond.

The runtime-isolation refactor inverts the daemon: it no longer embeds pi, it
spawns `pi --mode rpc` per session and drives it over a JSON-line pipe. So this
boots the real supervisor against the reused stub pi (SPACES_SESSIOND_PI_BIN)
and opens the confirm side-channel the natural way: a prompt whose message
contains CONFIRM makes the child emit an `extension_ui_request` and wait for the
`extension_ui_response`. The supervisor surfaces/relays that request over the
§12 WebSocket protocol exactly as before, so the three supervisor-side
assertions are unchanged:

  1. first-answer-wins — two clients mirror one session and both answer the same
     extension_ui_request; the child must receive exactly ONE response (the turn
     completes once), and the loser must get a `sidechannel_resolved`.
  2. park — a zero-client extension_ui_request marks the session `parked`
     (visible via list_sessions), survives, and is resolvable on re-attach.
  3. notifier — a zero-client park fires SPACES_SESSIOND_NOTIFY_CMD out-of-band.

Usage: driver.py <daemon_bin> <stub_pi> <notify_cmd>
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
NOTIFY_OUT = ""  # set by main(); the notifier stub appends parked requests here


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

        # CONFIRM makes the stub child raise an extension_ui_request and defer
        # agent_end until the answer crosses the rpc pipe back.
        await a.send(cmd(sid, {"type": "prompt", "message": "CONFIRM go"}))

        # Both mirrored clients must see the side-channel request.
        req_a = await drain_for(a, lambda e: e.get("type") == "extension_ui_request")
        req_b = await drain_for(b, lambda e: e.get("type") == "extension_ui_request")
        if not req_a or not req_b:
            fail(f"both clients should see the request (a={req_a!r}, b={req_b!r})")
        rid = req_a["id"]

        # Both answer the same id. First wins; the other is dropped + told resolved.
        await a.send(
            cmd(sid, {"type": "extension_ui_response", "id": rid, "confirmed": True})
        )
        await b.send(
            cmd(sid, {"type": "extension_ui_response", "id": rid, "confirmed": False})
        )

        msgs_a, msgs_b = await asyncio.gather(collect_all(a), collect_all(b))

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
            if m.get("kind") == "event"
            and (m.get("payload") or {}).get("type") == "agent_end"
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
        await a.send(cmd(sid, {"type": "prompt", "message": "CONFIRM go"}))
        await wait_state(sid, "parked")

        # The zero-client park must fire the notifier (block-and-notify, §6/§7).
        marked = ""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                with open(NOTIFY_OUT) as fh:
                    marked = fh.read()
            except FileNotFoundError:
                marked = ""
            if sid in marked:
                break
            await asyncio.sleep(0.2)
        else:
            fail("notifier did not fire when the request parked")
        if "confirm" not in marked:
            fail(f"notifier missing the parked method: {marked!r}")

        # Re-attach: the buffered request replays; answering it unparks the session.
        await a.send(
            json.dumps({"v": 1, "kind": "attach", "sessionId": sid, "lastSeq": 0})
        )
        await recv_kind(a, "attached")
        req = await drain_for(a, lambda e: e.get("type") == "extension_ui_request")
        if not req:
            fail("re-attach did not replay the parked request")
        await a.send(
            cmd(
                sid,
                {"type": "extension_ui_response", "id": req["id"], "confirmed": True},
            )
        )
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
    global NOTIFY_OUT
    if len(sys.argv) < 5:
        fail("usage: driver.py <daemon_bin> <stub_pi> <notify_cmd> <systemd_run>")
    daemon_bin, stub_pi, notify_cmd, systemd_run = sys.argv[1:5]

    state = tempfile.mkdtemp(prefix="sessiond-")
    NOTIFY_OUT = os.path.join(state, "notified")
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(PORT),
            "SPACES_SESSIOND_TOKEN": TOKEN,
            # The supervisor spawns this per session; the stub speaks rpc-mode
            # and opens the confirm side-channel on a CONFIRM prompt.
            "SPACES_SESSIOND_PI_BIN": stub_pi,
            "SPACES_SESSIOND_STATE_DIR": state,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",  # disable idle-GC for determinism
            "SPACES_SESSIOND_NOTIFY_CMD": notify_cmd,
            "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
            "NOTIFY_OUT": NOTIFY_OUT,
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
