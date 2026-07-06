#!/usr/bin/env python3
"""SignalConfirm contract test.

Drives the QML SignalConfirm component against a hand-rolled fake of
the spaces-signal-bridge panel socket protocol. The real bridge is
covered by packages/signal-cli/test_bridge.py; this test isolates
the QML state machine — subscribe, snapshot, added, removed, and
approve/deny round-trip.

No pi process, no signal-cli, no compositor. ~3-5s.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from qs_harness import Quickshell, fail, qs_env, reap, stage_shell
from qs_harness import wait_until as _wait_until


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1):
    return _wait_until(predicate, timeout_s=timeout_s, interval_s=interval_s)


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    sock_path = os.path.join(work_dir, "panel.sock")
    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    fake_bridge_py = os.path.join(test_dir, "fake_bridge.py")
    bridge = subprocess.Popen(
        [sys.executable, fake_bridge_py, sock_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    def bridge_cmd(cmd: str) -> str:
        bridge.stdin.write(cmd + "\n")
        bridge.stdin.flush()
        return bridge.stdout.readline().strip()

    if bridge.stdout.readline().strip() != "READY":
        fail("fake bridge did not signal READY")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "TEST_SIGNAL_PANEL_SOCK": sock_path,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:signal-confirm")
    qs.start()

    def qs_ipc_call(_qs_bin: str, _shell_qml: str, _env: dict, *args: str) -> str:
        return qs.ipc(*args)

    def cleanup_logs():
        qs.dump_logs()

    try:
        if not wait_until(qs.ipc_ready, timeout_s=20):
            cleanup_logs()
            fail("IPC never registered")

        # ── connectivity ──────────────────────────────────────────────
        if not wait_until(
            lambda: qs_ipc_call(qs_bin, shell_qml, env, "connected").strip() == "true",
            timeout_s=5,
        ):
            cleanup_logs()
            fail("SignalConfirm never connected to the fake bridge socket")

        # Initial snapshot is empty.
        if not wait_until(
            lambda: json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending")) == [],
            timeout_s=3,
        ):
            actual = qs_ipc_call(qs_bin, shell_qml, env, "pending")
            cleanup_logs()
            fail(f"expected empty initial pending, got {actual!r}")

        # ── push a snapshot with one pre-existing pending row ─────────
        bridge_cmd(
            "push_snapshot "
            + json.dumps(
                [
                    {
                        "token": "tok-pre",
                        "recipient": "+15559998888",
                        "display_name": "Bob",
                        "body": "preexisting",
                        "created_at": 1000,
                    }
                ]
            )
        )
        if not wait_until(
            lambda: any(
                p["token"] == "tok-pre"
                for p in json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending"))
            ),
            timeout_s=3,
        ):
            cleanup_logs()
            fail("snapshot row never reached the QML pending list")

        # ── push live `added` event ───────────────────────────────────
        bridge_cmd(
            "push_added "
            + json.dumps(
                {
                    "token": "tok-new",
                    "recipient": "+15557776666",
                    "display_name": "Carol",
                    "body": "live add",
                    "created_at": 2000,
                }
            )
        )
        if not wait_until(
            lambda: any(
                p["token"] == "tok-new"
                for p in json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending"))
            ),
            timeout_s=3,
        ):
            cleanup_logs()
            fail("added event did not update pending list")

        # Newest first: tok-new (created_at=2000) should be before tok-pre (1000).
        ordered = json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending"))
        tokens = [p["token"] for p in ordered]
        if tokens.index("tok-new") > tokens.index("tok-pre"):
            cleanup_logs()
            fail(f"pending list not newest-first: tokens={tokens}")

        # ── approve via IPC; bridge must see it; row must vanish ──────
        qs_ipc_call(qs_bin, shell_qml, env, "approve", "tok-new")
        if bridge_cmd("expect_approve tok-new") != "OK":
            cleanup_logs()
            fail("bridge never observed approve op for tok-new")
        if not wait_until(
            lambda: all(
                p["token"] != "tok-new"
                for p in json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending"))
            ),
            timeout_s=3,
        ):
            cleanup_logs()
            fail("pending list did not drop approved token")

        # ── deny via IPC; same flow ───────────────────────────────────
        qs_ipc_call(qs_bin, shell_qml, env, "deny", "tok-pre")
        if bridge_cmd("expect_deny tok-pre") != "OK":
            cleanup_logs()
            fail("bridge never observed deny op for tok-pre")
        if not wait_until(
            lambda: json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending")) == [],
            timeout_s=3,
        ):
            cleanup_logs()
            fail("pending list did not empty after deny")

        # ── independent `removed` event from a different decision ─────
        bridge_cmd(
            "push_added "
            + json.dumps(
                {
                    "token": "tok-passive",
                    "recipient": "+15554443333",
                    "display_name": "Dave",
                    "body": "x",
                    "created_at": 3000,
                }
            )
        )
        if not wait_until(
            lambda: any(
                p["token"] == "tok-passive"
                for p in json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending"))
            ),
            timeout_s=3,
        ):
            cleanup_logs()
            fail("tok-passive never landed")
        bridge_cmd("push_removed tok-passive")
        if not wait_until(
            lambda: all(
                p["token"] != "tok-passive"
                for p in json.loads(qs_ipc_call(qs_bin, shell_qml, env, "pending"))
            ),
            timeout_s=3,
        ):
            cleanup_logs()
            fail("passive removed event did not clear the row")

        print("OK")
    finally:
        qs.stop()
        try:
            bridge.stdin.write("quit\n")
            bridge.stdin.flush()
        except OSError:
            pass
        reap(bridge, timeout_s=2)


if __name__ == "__main__":
    main()
