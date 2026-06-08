#!/usr/bin/env python3
"""Headless check: a create_session lost to a connection flap is retried.

Runs the real PiExecutor + PiSession (WS mode) in headless quickshell
against a fake pi-sessiond that DROPS the first create_session mid-flight
(no ack) — the boot-time flap the real daemon shows while coming up — and
accepts the create only on reconnect.

A single send() buffers its prompt behind the in-flight create. The panel
must observe the drop, reconnect, RETRY the create, attach, and flush the
buffered prompt so the reply finally streams. Without a retry the prompt
sits buffered forever and the reply never arrives (the failure mode a
spawn-idempotency guard invites when it coalesces repeat spawns).

No compositor, no pi, no LLM, no VM. ~5s.

Usage: driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir>
"""

import os
import shutil
import socket
import subprocess
import sys
import time

EXPECTED = "Reply after the retried create"
TOKEN = "ws-retry-secret"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def wait_for_port(port: int, *, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    root = os.path.join(work_dir, "shell")
    os.makedirs(root, exist_ok=True)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), os.path.join(root, "shell.qml"))
    for f in ("PiExecutor.qml", "PiSession.qml"):
        shutil.copy2(os.path.join(plugin_dir, f), os.path.join(root, f))
    shutil.copytree(
        os.path.join(plugin_dir, "Commons"),
        os.path.join(root, "Commons"),
        dirs_exist_ok=True,
    )
    now = time.time()
    for r, _dirs, files in os.walk(root):
        for f in files:
            try:
                os.utime(os.path.join(r, f), (now, now))
            except OSError:
                pass
    return os.path.join(root, "shell.qml")


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    port = free_port()
    ws_url = f"ws://127.0.0.1:{port}"

    xdg = os.path.join(work_dir, "xdg")
    os.makedirs(xdg, exist_ok=True)
    os.chmod(xdg, 0o700)
    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)

    daemon_log = open(os.path.join(work_dir, "daemon.log"), "w")
    daemon = subprocess.Popen(
        [sys.executable, os.path.join(test_dir, "fake-daemon.py"), str(port), TOKEN],
        stdout=daemon_log,
        stderr=subprocess.STDOUT,
    )

    if not wait_for_port(port, timeout_s=15):
        sys.stderr.write(
            "\n== daemon.log ==\n" + open(os.path.join(work_dir, "daemon.log")).read()
        )
        fail(f"fake daemon never listened on port {port} (exit={daemon.poll()})")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "NIXPKGS_QT6_QML_IMPORT_PATH": os.environ.get(
            "NIXPKGS_QT6_QML_IMPORT_PATH", ""
        ),
        "PI_WS_URL": ws_url,
        "PI_WS_TOKEN": TOKEN,
    }

    qs_out = open(os.path.join(work_dir, "qs.out.log"), "w")
    qs_err = open(os.path.join(work_dir, "qs.err.log"), "w")
    qs = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_out, stderr=qs_err
    )

    def dump():
        for name in ("qs.out.log", "qs.err.log", "daemon.log"):
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {name} ==\n" + open(path).read())

    def die(msg):
        dump()
        fail(msg)

    def ipc(*args):
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "call", "test:retry", *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if r.returncode != 0:
            raise RuntimeError(f"ipc {args} failed (exit={r.returncode}): {r.stderr!r}")
        return r.stdout.strip()

    def ipc_ready():
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "show"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and "test:retry" in r.stdout

    try:
        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:retry IPC target")

        if not wait_until(lambda: ipc("connected") == "true", timeout_s=15):
            die("panel never connected/authenticated over WS")

        # One send: its prompt is buffered behind the create that the daemon
        # drops. Only a retried create can attach and flush it.
        ipc("send", "hi")

        # Generous timeout: the executor reconnects on a ~1s backoff, then the
        # retried create acks and the buffered prompt flushes.
        if not wait_until(lambda: EXPECTED in ipc("reply"), timeout_s=40):
            die(
                "reply never streamed — the create_session dropped by the flap "
                f"was not retried (reply={ipc('reply')!r})"
            )

        sys.stderr.write("PASS: create_session retried across the connection flap\n")
    finally:
        qs.terminate()
        try:
            qs.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs.kill()
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()


if __name__ == "__main__":
    main()
