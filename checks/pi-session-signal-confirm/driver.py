#!/usr/bin/env python3
"""SignalConfirm contract test.

Drives the QML SignalConfirm component against a hand-rolled fake of
the distro-signal-bridge panel socket protocol. The real bridge is
covered by packages/signal-cli/test_bridge.py; this test isolates
the QML state machine — subscribe, snapshot, added, removed, and
approve/deny round-trip.

No pi process, no signal-cli, no compositor. ~3-5s.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"),
        os.path.join(shell_root, "shell.qml"),
    )
    shutil.copytree(
        os.path.join(test_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    shutil.copy2(
        os.path.join(plugin_dir, "SignalConfirm.qml"),
        os.path.join(shell_root, "SignalConfirm.qml"),
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:signal-confirm", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

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

    env = os.environ.copy()
    env.update(
        {
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "TEST_SIGNAL_PANEL_SOCK": sock_path,
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def cleanup_logs():
        try:
            qs_log.flush()
            with open(os.path.join(work_dir, "qs.log")) as fh:
                sys.stderr.write("\n== qs.log ==\n")
                sys.stderr.write(fh.read())
        except Exception:
            pass

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:signal-confirm" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
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
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()
        try:
            bridge.stdin.write("quit\n")
            bridge.stdin.flush()
        except OSError:
            pass
        try:
            bridge.wait(timeout=2)
        except subprocess.TimeoutExpired:
            bridge.kill()


if __name__ == "__main__":
    main()
