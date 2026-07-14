#!/usr/bin/env python3
"""Daemon-level check: the selected model survives cold resume.

Two seams, both against the real pi-sessiond with a stub pi child that
records the argv it was spawned with:

  1. set_model must update the session's meta sidecar. The sidecar is
     what spawnSessionDriver passes as --provider/--model on a cold
     resume, and pi's CLI --model OVERRIDES the session.jsonl restore —
     so a stale sidecar silently reverts the session to its create-time
     model after idle GC or a daemon restart (the production "restart
     the stack, history shows the picked model, replies use the
     default" bug). Assert: create → set_model(other) → daemon restart
     → attach respawns the child with --model <other>.

  2. create_session with model="provider/id" (the panel's PiSession
     sends the combined modelPref, no separate provider field) must
     split it via the registry instead of defaulting provider to
     "local" with the combined string as the model id. Assert the meta
     sidecar and the child argv carry provider="local",
     model="other-model" for model="local/other-model".

A tiny /v1/models HTTP server stands in for llama-swap so the daemon's
boot-time discovery registers TWO local models (mock-model,
other-model) — otherwise set_model(other-model) bounces on "unknown
model". Real daemon + stub pi. No LLM, no VM, ~5s.
"""

import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import websockets

TOKEN = "model-persist-secret"
PORT = 8791
LLM_PORT = 8792


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def uri():
    return f"ws://127.0.0.1:{PORT}"


class ModelsHandler(BaseHTTPRequestHandler):
    """Serves GET /v1/models with two local models; llama-swap stand-in."""

    def do_GET(self):
        if self.path != "/v1/models":
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(
            {"data": [{"id": "mock-model"}, {"id": "other-model"}]}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


async def hello(ws):
    await ws.send(json.dumps({"v": 1, "kind": "hello", "token": TOKEN}))
    msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
    if msg.get("kind") != "welcome":
        fail(f"hello failed: {msg}")


async def create_session(ws, name, model=None):
    env = {"v": 1, "kind": "create_session", "name": name}
    if model is not None:
        env["model"] = model
    await ws.send(json.dumps(env))
    while True:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=15))
        if msg.get("kind") == "attached":
            return msg["sessionId"]
        if msg.get("kind") == "error":
            fail(f"create_session failed: {msg}")


async def command_response(ws, sid, payload, command, timeout=15):
    await ws.send(
        json.dumps({"v": 1, "kind": "command", "sessionId": sid, "payload": payload})
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
        if msg.get("kind") != "event":
            continue
        p = msg.get("payload") or {}
        if p.get("type") == "response" and p.get("command") == command:
            return p
        if p.get("type") == "error" and p.get("command") == command:
            fail(f"{command} errored: {p}")
    fail(f"no response for {command}")
    return None  # unreachable


def read_meta(state, sid):
    path = os.path.join(state, "sessions", f"{sid}.meta.json")
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def read_spawn_argv(state, sid):
    """The stub pi appends one JSON line of its argv per spawn."""
    path = os.path.join(state, f"spawn-{sid}.log")
    try:
        with open(path) as fh:
            lines = [ln.strip() for ln in fh if ln.strip()]
        return [json.loads(ln) for ln in lines]
    except (OSError, ValueError):
        return []


def argv_model(argv):
    out = {}
    for flag in ("--provider", "--model"):
        try:
            out[flag] = argv[argv.index(flag) + 1]
        except (ValueError, IndexError):
            out[flag] = None
    return out


def wait_port(port, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    fail(f"daemon never opened port {port}")


def spawn_daemon(daemon_bin, stub_pi, systemd_run, state, log):
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(PORT),
            "SPACES_SESSIOND_TOKEN": TOKEN,
            "SPACES_SESSIOND_PI_BIN": stub_pi,
            "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
            "LLAMA_SWAP_BASE_URL": f"http://127.0.0.1:{LLM_PORT}",
            "SPACES_SESSIOND_DEFAULT_MODEL": "mock-model",
            "SPACES_SESSIOND_STATE_DIR": state,
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
            "HOME": state,
            # The child unit gets a fresh env; ride the module's session-env
            # seam so the stub finds its spawn-log dir.
            "SPACES_SESSIOND_SESSION_ENV": json.dumps({"STUB_PI_LOG_DIR": state}),
        }
    )
    return subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)


async def scenario_set_model_updates_meta(state):
    """Create on the default → set_model(other) → meta sidecar updated."""
    async with websockets.connect(uri()) as ws:
        await hello(ws)
        sid = await create_session(ws, "persist")
        meta = read_meta(state, sid)
        if not meta or meta.get("model") != "mock-model":
            fail(f"create meta wrong: {meta!r}")
        resp = await command_response(
            ws,
            sid,
            {"type": "set_model", "provider": "local", "modelId": "other-model"},
            "set_model",
        )
        if not resp.get("success"):
            fail(f"set_model failed: {resp}")
        meta = read_meta(state, sid)
        if not meta or meta.get("model") != "other-model":
            fail(
                "set_model did not update the meta sidecar "
                f"(cold resume would revert the model): {meta!r}"
            )
        return sid


async def scenario_cold_resume_uses_new_model(sid, state):
    """After a daemon restart, attach must spawn pi with the picked model."""
    async with websockets.connect(uri()) as ws:
        await hello(ws)
        await ws.send(
            json.dumps({"v": 1, "kind": "attach", "sessionId": sid, "lastSeq": 0})
        )
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
            if msg.get("kind") == "attached" and msg.get("sessionId") == sid:
                break
            if msg.get("kind") == "error":
                fail(f"cold attach bounced: {msg}")
    # The attach ack is sent as soon as the supervisor registers the
    # session; the respawned child (which writes its argv record on
    # startup) comes up asynchronously — poll instead of reading once.
    deadline = time.monotonic() + 15
    spawns = read_spawn_argv(state, sid)
    while len(spawns) < 2 and time.monotonic() < deadline:
        await asyncio.sleep(0.2)
        spawns = read_spawn_argv(state, sid)
    if len(spawns) < 2:
        fail(f"expected a second spawn after cold attach, got {len(spawns)}")
    got = argv_model(spawns[-1])
    if got["--model"] != "other-model":
        fail(
            "cold resume respawned pi with the stale create-time model: "
            f"argv carried {got!r}, expected --model other-model"
        )


async def scenario_create_splits_combined_model(state):
    """create_session model='local/other-model' → provider/id split."""
    async with websockets.connect(uri()) as ws:
        await hello(ws)
        sid = await create_session(ws, "combined", model="local/other-model")
        meta = read_meta(state, sid)
        if not meta:
            fail("no meta sidecar for combined-model create")
        if meta.get("provider") != "local" or meta.get("model") != "other-model":
            fail(
                "create_session did not split the combined provider/id "
                f"model: meta={meta!r}"
            )
        # The child (which records its argv on startup) comes up
        # asynchronously after the attach ack — poll.
        deadline = time.monotonic() + 15
        spawns = read_spawn_argv(state, sid)
        while not spawns and time.monotonic() < deadline:
            await asyncio.sleep(0.2)
            spawns = read_spawn_argv(state, sid)
        if not spawns:
            fail("no spawn recorded for combined-model create")
        got = argv_model(spawns[0])
        if got["--provider"] != "local" or got["--model"] != "other-model":
            fail(f"child argv carried unsplit model: {got!r}")


def main():
    if len(sys.argv) < 4:
        fail("usage: driver.py <daemon_bin> <stub_pi> <systemd_run>")
    daemon_bin, stub_pi, systemd_run = sys.argv[1], sys.argv[2], sys.argv[3]

    httpd = HTTPServer(("127.0.0.1", LLM_PORT), ModelsHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    state = tempfile.mkdtemp(prefix="sessiond-model-")
    log_path = os.path.join(state, "daemon.log")
    log = open(log_path, "wb")
    proc = spawn_daemon(daemon_bin, stub_pi, systemd_run, state, log)
    try:
        wait_port(PORT)
        sid = asyncio.run(scenario_set_model_updates_meta(state))

        # Restart: the in-memory registry dies; resume must read the sidecar.
        proc.terminate()
        proc.wait(timeout=10)
        proc = spawn_daemon(daemon_bin, stub_pi, systemd_run, state, log)
        wait_port(PORT)

        asyncio.run(scenario_cold_resume_uses_new_model(sid, state))
        asyncio.run(scenario_create_splits_combined_model(state))
        print("PASS: set_model persists to meta; combined model splits")
    except SystemExit:
        log.flush()
        with open(log_path) as fh:
            sys.stderr.write("=== daemon log ===\n" + fh.read())
        raise
    finally:
        httpd.shutdown()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
