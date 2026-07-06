#!/usr/bin/env python3
"""Headless check: the chat panel drives a session over the §12 WebSocket
transport.

Runs the real PiExecutor + PiSession (WS mode) in a headless quickshell
against a fake pi-sessiond, then asserts the panel:
  - connects + authenticates with a token read from a file (hello -> welcome),
  - creates a session and sends a prompt over the wire,
  - renders the streamed reply ("Hello, world!") into session.messages.

This is the cheap per-feature counterpart to the full two-VM test: no
compositor, no pi, no LLM, no VM. ~5s.

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

EXPECTED = "Hello, world!"
CAUGHT_UP = "Caught up!"
TOKEN = "ws-check-secret"


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

    # Avoid a connect race: the WebSocket connects once and does not retry,
    # so the daemon must be listening before quickshell starts.
    if not wait_for_port(port, timeout_s=15):
        sys.stderr.write(
            "\n== daemon.log ==\n" + open(os.path.join(work_dir, "daemon.log")).read()
        )
        fail(f"fake daemon never listened on port {port} (exit={daemon.poll()})")

    # The panel authenticates with a token read from a file (PI_WS_TOKEN_PATH) —
    # the production secret path (/run/spaces-secrets) — not an inline value. The
    # trailing newline ensures the panel's read is trimmed.
    token_path = os.path.join(work_dir, "ws-token")
    with open(token_path, "w") as fh:
        fh.write(TOKEN + "\n")

    env = qs_env(
        work_dir,
        extra={
            "PI_WS_URL": ws_url,
            "PI_WS_TOKEN": "",
            "PI_WS_TOKEN_PATH": token_path,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:ws")
    qs.start()

    def die(msg):
        qs.die(msg, extra_logs=("daemon.log",))

    ipc = qs.ipc

    try:
        qs.wait_ipc_ready(timeout_s=20, extra_logs=("daemon.log",))

        if not wait_until(lambda: ipc("connected") == "true", timeout_s=15):
            die("panel never connected/authenticated over WS (token read from file)")

        ipc("send", "hi")

        # Turn 1 streams live over the first connection.
        if not wait_until(lambda: EXPECTED in ipc("reply"), timeout_s=30):
            die(
                f"turn 1 never streamed over WS (reply={ipc('reply')!r}, count={ipc('msgCount')})"
            )

        # The fake daemon buffers a turn the client MISSES, then drops the
        # connection. The panel must observe the drop, reconnect, re-attach with
        # lastSeq, and replay the missed turn (reconnect-with-history).
        if not wait_until(lambda: ipc("connected") == "false", timeout_s=15):
            die("panel never saw the executor connection drop")
        if not wait_until(lambda: ipc("connected") == "true", timeout_s=15):
            die("panel never reconnected to the executor")
        if not wait_until(lambda: CAUGHT_UP in ipc("reply"), timeout_s=30):
            die(f"panel never caught up to the missed turn (reply={ipc('reply')!r})")

        # Side-channel: a "confirm" prompt opens a pending confirm bubble;
        # sidechannel_resolved (another mirrored client answered first) must
        # collapse it (first-answer-wins, design §6).
        ipc("send", "confirm")
        if not wait_until(
            lambda: ipc("confirmState", "sc-1") == "pending", timeout_s=15
        ):
            die(
                f"confirm bubble never appeared (state={ipc('confirmState', 'sc-1')!r})"
            )
        ipc("send", "resolve")
        if not wait_until(
            lambda: ipc("confirmState", "sc-1") == "resolved", timeout_s=15
        ):
            die(
                f"confirm not collapsed on resolve (state={ipc('confirmState', 'sc-1')!r})"
            )

        sys.stderr.write(
            "PASS: token-from-file auth + reconnect catch-up + sidechannel_resolved collapse\n"
        )
    finally:
        qs.stop()
        reap(daemon)


if __name__ == "__main__":
    main()
