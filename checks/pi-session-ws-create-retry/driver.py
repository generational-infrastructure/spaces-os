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
import sys

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

EXPECTED = "Reply after the retried create"
TOKEN = "ws-retry-secret"


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    port = free_port()
    ws_url = f"ws://127.0.0.1:{port}"

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    daemon = spawn(
        [sys.executable, os.path.join(test_dir, "fake-daemon.py"), str(port), TOKEN],
        work_dir,
        "daemon.log",
    )

    if not wait_for_port(port, timeout_s=15):
        sys.stderr.write(
            "\n== daemon.log ==\n" + open(os.path.join(work_dir, "daemon.log")).read()
        )
        fail(f"fake daemon never listened on port {port} (exit={daemon.poll()})")

    env = qs_env(
        work_dir,
        extra={
            "PI_WS_URL": ws_url,
            "PI_WS_TOKEN": TOKEN,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:retry")
    qs.start()

    def die(msg):
        qs.die(msg, extra_logs=("daemon.log",))

    ipc = qs.ipc

    try:
        qs.wait_ipc_ready(timeout_s=20, extra_logs=("daemon.log",))

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
        qs.stop()
        reap(daemon)


if __name__ == "__main__":
    main()
