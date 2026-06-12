#!/usr/bin/env python3
"""Create-ack routing contract.

A persisted entry re-attaches (plain attach ack) while a brand-new
session's create_session is in flight on the same executor connection.
The attach ack must not consume the pending create's FIFO resolver:
pre-fix, the new entry was stamped with the PERSISTED session's daemon
id (two tabs sharing one daemon session) and the real create ack
resolved nothing. The fake daemon forces the interleave
deterministically by withholding the attach ack until the create
arrives, then sending attach-ack before create-ack.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time

TOKEN = "ack-routing-secret"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval_s)
    return None


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    shutil.copytree(plugin_dir, shell_root, dirs_exist_ok=True)
    for root, _dirs, files in os.walk(shell_root):
        os.chmod(root, 0o755)
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o644)
            except OSError:
                pass
    shell_dst = os.path.join(shell_root, "shell.qml")
    if os.path.exists(shell_dst):
        os.remove(shell_dst)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), shell_dst)
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def stage_index(home: str) -> None:
    """One persisted entry bound to the fake daemon's known session."""
    state_dir = os.path.join(home, ".local", "state", "spaces", "pi")
    os.makedirs(state_dir, exist_ok=True)
    now_ms = int(time.time() * 1000)
    index = {
        "version": 1,
        "activeSessionId": "persisted0001",
        "lastImportTime": now_ms,
        "sessions": [
            {
                "id": "persisted0001",
                "name": "Chat 1",
                "workspacePath": os.path.join(home, "workspace"),
                "executor": "host",
                "daemonSessionId": "sess-persisted",
                "model": "",
                "trusted": False,
                "unread": 0,
                "memoryEnabled": True,
                "createdAt": now_ms,
                "lastActiveAt": now_ms,
            }
        ],
    }
    with open(os.path.join(state_dir, "sessions.json"), "w") as fh:
        json.dump(index, fh)


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)
    stage_index(home)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    port = free_port()
    daemon_log = open(os.path.join(work_dir, "daemon.log"), "w")
    daemon = subprocess.Popen(
        [
            sys.executable,
            os.path.join(test_dir, "fake-daemon.py"),
            str(port),
            TOKEN,
        ],
        stdout=subprocess.PIPE,
        stderr=daemon_log,
    )
    if not daemon.stdout.readline():
        fail("fake daemon never came up")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_CONFIG": os.path.join(work_dir, "no-config.json"),
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [{"id": "host", "url": f"ws://127.0.0.1:{port}", "token": TOKEN}]
            ),
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def ipc(*args: str, check: bool = True) -> str:
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:ack-routing", *args]
        out = subprocess.run(cmd, env=env, capture_output=True, text=True)
        if check and out.returncode != 0:
            fail(f"ipc {args} failed: {out.stdout!r} {out.stderr!r}")
        return out.stdout.strip()

    def dump_and_fail(msg: str) -> None:
        for name in ("daemon.log", "qs.log"):
            path = os.path.join(work_dir, name)
            if os.path.exists(path):
                with open(path, errors="replace") as fh:
                    sys.stderr.write(f"== {name} ==\n" + fh.read())
        fail(msg)

    try:
        if not wait_until(lambda: ipc("ping", check=False) == "true", timeout_s=60):
            dump_and_fail("shell IPC never came up")

        # Spawn the persisted session (attach goes out; ack is withheld
        # daemon-side), then immediately create a second session — its
        # create_session races the still-pending attach ack.
        def spawned():
            ipc("openPanel")
            raw = json.loads(ipc("rawSessions"))
            return raw and raw[0]["daemonSessionId"] == "sess-persisted"

        if not wait_until(spawned, timeout_s=60):
            dump_and_fail(f"persisted entry never loaded: {ipc('rawSessions')}")

        new_id = ipc("newSession", "Racer")
        if not new_id:
            dump_and_fail("newSession returned no id")

        def stamped():
            raw = json.loads(ipc("rawSessions"))
            entry = next((s for s in raw if s["id"] == new_id), None)
            return entry and entry["daemonSessionId"] != ""

        if not wait_until(stamped, timeout_s=30):
            dump_and_fail(f"create never acked: {ipc('rawSessions')}")

        raw = json.loads(ipc("rawSessions"))
        by_id = {s["id"]: s for s in raw}
        racer = by_id[new_id]
        persisted = by_id["persisted0001"]
        if racer["daemonSessionId"] == "sess-persisted":
            dump_and_fail(
                "attach ack consumed the pending create: the new session was "
                f"stamped with the persisted daemon id: {raw}"
            )
        if not racer["daemonSessionId"].startswith("sess-created-"):
            dump_and_fail(f"new session got an unexpected daemon id: {raw}")
        if persisted["daemonSessionId"] != "sess-persisted":
            dump_and_fail(f"persisted entry lost its daemon id: {raw}")
        print("OK: create ack routed to the creating session, attach ack ignored")
    finally:
        qs.terminate()
        daemon.terminate()


if __name__ == "__main__":
    main()
