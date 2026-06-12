#!/usr/bin/env python3
"""Daemon-level focused check: envelope ordering across a cold attach.

The panel's attach path (PiSession._wsSpawn) sends `attach` and
immediately pipelines session commands (set_memory,
get_available_models, get_state, get_messages) on the same socket
without waiting for the `attached` ack. WebSocket framing guarantees
the daemon RECEIVES them in order — the contract is that it also
PROCESSES them in order. A cold attach awaits resumeSession (SDK
session reload, agent construction); if the command envelopes are
dispatched concurrently instead of queued behind it, they look up an
id that isn't registered yet and every one dies with "no such
session": the session attaches but the panel never gets models or
history. Seen in production as a model-less, unusable chat after a
daemon restart.

Three scenarios against the real daemon, no LLM, no VM, ~5s:
  1. cold attach + pipelined command answers (the ordering contract)
  2. attach to a meta-only session (created but no turn ever ran →
     no committed jsonl) resurrects it instead of failing
  3. attach/command on an unknown id errors WITH the sessionId echoed
     so a multiplexing client can route the failure to its session
"""

import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid

import websockets

TOKEN = "cold-attach-secret"
PORT = 8773


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def uri():
    return f"ws://127.0.0.1:{PORT}"


async def hello(ws):
    await ws.send(json.dumps({"v": 1, "kind": "hello", "token": TOKEN}))
    msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
    if msg.get("kind") != "welcome":
        fail(f"hello failed: {msg}")


async def create_session(ws, name):
    await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": name}))
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
        if msg.get("kind") == "attached":
            return msg["sessionId"]
        if msg.get("kind") == "error":
            fail(f"create_session failed: {msg}")


async def scenario_cold_attach_pipelined(sid):
    """attach + immediate command on one socket: the command MUST be
    answered (processed after the resume finishes), not bounced."""
    async with websockets.connect(uri()) as ws:
        await hello(ws)
        # Pipelined burst, exactly like the panel's _wsSpawn + _wsFlush.
        await ws.send(
            json.dumps({"v": 1, "kind": "attach", "sessionId": sid, "lastSeq": 0})
        )
        await ws.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "command",
                    "sessionId": sid,
                    "payload": {"type": "get_available_models", "id": "q1"},
                }
            )
        )
        attached = False
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
            if msg.get("kind") == "attached" and msg.get("sessionId") == sid:
                attached = True
            elif msg.get("kind") == "error":
                fail(f"cold attach burst bounced: {msg}")
            elif msg.get("kind") == "event":
                payload = msg.get("payload") or {}
                if (
                    payload.get("type") == "response"
                    and payload.get("command") == "get_available_models"
                ):
                    if not attached:
                        fail("response arrived before attached ack (ordering)")
                    return
        fail("never saw the get_available_models response after cold attach")


async def scenario_meta_only_resurrect(state):
    """A session that was created but never ran a turn persists only its
    meta sidecar (no jsonl). Attach must resurrect it, not bounce."""
    sid = str(uuid.uuid4())
    sessions_dir = os.path.join(state, "sessions")
    os.makedirs(os.path.join(sessions_dir, sid), exist_ok=True)
    with open(os.path.join(sessions_dir, f"{sid}.meta.json"), "w") as fh:
        json.dump({"provider": "local", "model": "mock-model", "name": "turnless"}, fh)
    async with websockets.connect(uri()) as ws:
        await hello(ws)
        await ws.send(
            json.dumps({"v": 1, "kind": "attach", "sessionId": sid, "lastSeq": 0})
        )
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
            if msg.get("kind") == "attached" and msg.get("sessionId") == sid:
                return
            if msg.get("kind") == "error":
                fail(f"meta-only attach bounced: {msg}")


async def scenario_unknown_id_error_carries_session_id():
    """Errors for session-scoped envelopes must echo the sessionId so a
    client multiplexing many sessions over one socket can route them."""
    ghost = str(uuid.uuid4())
    async with websockets.connect(uri()) as ws:
        await hello(ws)
        await ws.send(
            json.dumps({"v": 1, "kind": "attach", "sessionId": ghost, "lastSeq": 0})
        )
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
        if msg.get("kind") != "error":
            fail(f"attach to unknown id should error, got: {msg}")
        if msg.get("sessionId") != ghost:
            fail(f"attach error must carry sessionId={ghost}, got: {msg}")
        await ws.send(
            json.dumps(
                {
                    "v": 1,
                    "kind": "command",
                    "sessionId": ghost,
                    "payload": {"type": "get_state", "id": "q9"},
                }
            )
        )
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
        if msg.get("kind") != "error" or msg.get("sessionId") != ghost:
            fail(f"command error must carry sessionId={ghost}, got: {msg}")


def wait_port(port, timeout=30):
    import socket

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    fail(f"daemon never opened port {port}")


def spawn_daemon(daemon_bin, state, log):
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(PORT),
            "SPACES_SESSIOND_TOKEN": TOKEN,
            "LLAMA_SWAP_BASE_URL": "http://127.0.0.1:1",  # unused; no prompt
            "SPACES_SESSIOND_DEFAULT_MODEL": "mock-model",
            "SPACES_SESSIOND_STATE_DIR": state,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
            "HOME": state,
        }
    )
    return subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)


def main():
    if len(sys.argv) < 2:
        fail("usage: driver.py <daemon_bin>")
    daemon_bin = sys.argv[1]

    state = tempfile.mkdtemp(prefix="sessiond-cold-")
    log_path = os.path.join(state, "daemon.log")
    log = open(log_path, "wb")

    proc = spawn_daemon(daemon_bin, state, log)
    try:
        wait_port(PORT)

        # Seed a session, then restart the daemon so the next attach is a
        # genuine cold resume (in-memory registry gone, state on disk).
        async def seed():
            async with websockets.connect(uri()) as ws:
                await hello(ws)
                return await create_session(ws, "alpha")

        sid = asyncio.run(seed())

        proc.terminate()
        proc.wait(timeout=10)
        proc = spawn_daemon(daemon_bin, state, log)
        wait_port(PORT)

        asyncio.run(scenario_cold_attach_pipelined(sid))
        asyncio.run(scenario_meta_only_resurrect(state))
        asyncio.run(scenario_unknown_id_error_carries_session_id())
        print("OK: cold attach ordering + meta-only resurrect + correlated errors")
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
