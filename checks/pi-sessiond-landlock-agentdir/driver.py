#!/usr/bin/env python3
"""Daemon-level check: each Landlock session gets its OWN writable agent dir.

Boots the real pi-sessiond under the Landlock branch (SPACES_SESSIOND_LANDLOCK_EXEC
points at a stub launcher that just execs the child) with a stub pi, creates two
sessions, and asserts per-session isolation of the pi agent dir (HOME /
PI_CODING_AGENT_DIR):

  - each session's agent dir is a per-session directory UNDER its own session
    dir, seeded with the static config (settings.json, bash-confirm.json);
  - the two sessions do NOT share an agent dir;
  - the emitted landlock policy grants that per-session tree rw and NEVER the
    daemon's shared `pi-agent` dir.

The agent-dir wiring is written synchronously while the session is created
(writeLandlockPolicy + the agent-dir seed run before the child is spawned), so
the assertions hold the moment `attached` comes back — the stub child need not
do anything. Real Landlock enforcement is covered by checks/pi-sessiond-landlock.

Real daemon + stub launcher + stub pi. No model, no VM. ~3s.
"""

import asyncio
import json
import os
import socket
import subprocess
import sys
import time

import websockets

PORT = 8782


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


async def create(ws, name):
    await ws.send(json.dumps({"v": 1, "kind": "create_session", "name": name}))
    while True:
        m = json.loads(await ws.recv())
        if m.get("kind") == "attached" and m.get("created"):
            return m["sessionId"]
        if m.get("kind") == "error":
            fail(f"create_session: {m}")


def all_parents(policy):
    return [p for r in policy.get("pathBeneath", []) for p in r.get("parent", [])]


def rw_parents(policy):
    out = []
    for r in policy.get("pathBeneath", []):
        if "abi.read_write" in r.get("allowedAccess", []):
            out += r.get("parent", [])
    return out


async def scenario(ws, state):
    await ws.send(json.dumps({"v": 1, "kind": "hello"}))
    if json.loads(await ws.recv()).get("kind") != "welcome":
        fail("hello did not yield welcome")

    shared_agent = os.path.join(state, "pi-agent")
    agent_dirs = []
    for name in ("one", "two"):
        sid = await create(ws, name)
        sdir = os.path.join(state, "sessions", sid)
        adir = os.path.join(sdir, "agent")
        agent_dirs.append(adir)

        # The per-session agent dir is seeded with the static config copies.
        for f in ("settings.json", "bash-confirm.json"):
            if not os.path.isfile(os.path.join(adir, f)):
                fail(f"{name}: per-session agent dir missing {f} (looked in {adir})")

        # The policy grants the per-session tree rw and never the shared dir.
        with open(os.path.join(sdir, "landlock.json")) as fh:
            pol = json.load(fh)
        if shared_agent in all_parents(pol):
            fail(f"{name}: policy grants the shared agent dir {shared_agent}")
        if sdir not in rw_parents(pol):
            fail(f"{name}: policy does not grant the session dir rw: {rw_parents(pol)}")

    if agent_dirs[0] == agent_dirs[1]:
        fail(f"two sessions share an agent dir: {agent_dirs[0]}")

    print(
        f"PASS: per-session agent dirs, no shared writable HOME: {agent_dirs}",
        flush=True,
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
    daemon_bin, stub_pi, systemd_run, launcher, settings, confirm = sys.argv[1:7]
    state = os.path.join(os.environ["TMPDIR"], "state")
    os.makedirs(state, exist_ok=True)
    env = dict(os.environ)
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(PORT),
            "SPACES_SESSIOND_PI_BIN": stub_pi,
            "SPACES_SESSIOND_SYSTEMD_RUN": systemd_run,
            # The Landlock branch: the daemon spawns the child through this.
            "SPACES_SESSIOND_LANDLOCK_EXEC": launcher,
            "SPACES_SESSIOND_PI_SETTINGS": settings,
            "SPACES_SESSIOND_BASH_CONFIRM": confirm,
            "SPACES_SESSIOND_STATE_DIR": state,
        }
    )
    log = open(os.path.join(state, "daemon.log"), "w")
    proc = subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        if not wait_port(PORT):
            fail(f"daemon never listened (exit={proc.poll()})")
        asyncio.run(asyncio.wait_for(_run(state), timeout=30))
    finally:
        proc.terminate()
        with open(os.path.join(state, "daemon.log")) as f:
            sys.stderr.write("=== daemon log ===\n" + f.read())


async def _run(state):
    async with websockets.connect(f"ws://127.0.0.1:{PORT}") as ws:
        await scenario(ws, state)


if __name__ == "__main__":
    main()
