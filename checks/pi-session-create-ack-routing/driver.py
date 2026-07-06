#!/usr/bin/env python3
"""Create-ack routing contract.

A persisted entry re-attaches (plain attach ack) while a brand-new
session's create_session is in flight on the same executor connection.
The attach ack must never be taken for the create's ack (which the
daemon marks `created` and stamps with the requestId echo): pre-fix
(FIFO resolution, no correlation id), the new entry was stamped with
the PERSISTED session's daemon id (two tabs sharing one daemon
session) and the real create ack resolved nothing. The fake daemon
forces the interleave deterministically by withholding the attach ack
until the create arrives, then sending attach-ack before create-ack.
"""

from __future__ import annotations

import json
import os
import sys
import time

from qs_harness import (
    Quickshell,
    fail,
    free_port,
    qs_env,
    reap,
    spawn,
    stage_shell,
    wait_for_port,
    wait_until,
)

TOKEN = "ack-routing-secret"


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

    stage_index(work_dir)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    port = free_port()
    daemon = spawn(
        [
            sys.executable,
            os.path.join(test_dir, "fake-daemon.py"),
            str(port),
            TOKEN,
        ],
        work_dir,
        "daemon.log",
    )
    if not wait_for_port(port, timeout_s=15):
        fail("fake daemon never came up")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_CONFIG": os.path.join(work_dir, "no-config.json"),
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [{"id": "host", "url": f"ws://127.0.0.1:{port}", "token": TOKEN}]
            ),
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:ack-routing")
    qs.start()

    ipc = qs.ipc

    def dump_and_fail(msg: str) -> None:
        qs.die(msg, extra_logs=("daemon.log",))

    try:
        qs.wait_ipc_ready(timeout_s=60, extra_logs=("daemon.log",))

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
        qs.stop()
        reap(daemon)


if __name__ == "__main__":
    main()
