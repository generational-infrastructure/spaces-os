#!/usr/bin/env python3
"""Headless check: the panel renders an integration tool-call approval and
replies the user's decision over the §12 WebSocket transport.

Runs the real PiExecutor + PiSession (WS mode) in a headless quickshell against
a fake gateway, then for each decision {once, session, deny} asserts:
  - a pending approval bubble appears carrying the gateway's tool + args,
  - after respond(), the bubble's state flips to that decision, and
  - the gateway actually received an approval_response{decision} on the wire
    (recorded to a file), proving the reply is sent — not merely patched local.

The cheap per-feature counterpart to the full VM test: no compositor, pi, LLM,
or VM. Usage: driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir>
"""

import json
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

TOKEN = "approval-check-secret"
DECISIONS = [("appr-once", "once"), ("appr-session", "session"), ("appr-deny", "deny")]


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    port = free_port()
    ws_url = f"ws://127.0.0.1:{port}"

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    record = os.path.join(work_dir, "responses.ndjson")

    daemon = spawn(
        [
            sys.executable,
            os.path.join(test_dir, "fake-daemon.py"),
            str(port),
            TOKEN,
            record,
        ],
        work_dir,
        "daemon.log",
    )

    if not wait_for_port(port, timeout_s=15):
        sys.stderr.write(
            "\n== daemon.log ==\n" + open(os.path.join(work_dir, "daemon.log")).read()
        )
        fail(f"fake gateway never listened on port {port} (exit={daemon.poll()})")

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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:approval")
    qs.start()

    def die(msg):
        qs.die(msg, extra_logs=("daemon.log",))

    ipc = qs.ipc

    def recorded():
        if not os.path.isfile(record):
            return []
        out = []
        for line in open(record):
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    try:
        qs.wait_ipc_ready(timeout_s=20, extra_logs=("daemon.log",))
        if not wait_until(lambda: ipc("connected") == "true", timeout_s=15):
            die("panel never connected/authenticated over WS")

        for idx, (appr_id, decision) in enumerate(DECISIONS):
            ipc("send", f"approve:{appr_id}")
            if not wait_until(
                lambda aid=appr_id: ipc("approvalState", aid) == "pending", timeout_s=15
            ):
                die(f"approval bubble {appr_id} never appeared pending")

            # First one: the panel must surface exactly what the gateway sent.
            if idx == 0:
                tool = ipc("approvalTool", appr_id)
                if tool != "github_create_issue":
                    die(f"approval bubble tool mismatch: {tool!r}")
                args = ipc("approvalArgs", appr_id)
                if "octo/repo" not in args or "hello" not in args:
                    die(f"approval bubble did not surface the gateway args: {args!r}")

            # Pre-decision: nothing recorded for this id yet.
            if any(r.get("id") == appr_id for r in recorded()):
                die(f"approval_response for {appr_id} recorded before the user decided")

            ipc("respond", appr_id, decision)
            if not wait_until(
                lambda aid=appr_id, d=decision: ipc("approvalState", aid) == d,
                timeout_s=15,
            ):
                die(f"approval bubble {appr_id} state never became {decision!r}")
            if not wait_until(
                lambda aid=appr_id, d=decision: any(
                    r.get("id") == aid and r.get("decision") == d for r in recorded()
                ),
                timeout_s=15,
            ):
                die(
                    f"gateway never received approval_response {{{appr_id}: {decision}}} on the wire"
                )

        # Preview context (decision 5): a confirmPreview tool's untrusted output
        # rides the approval as `context`; the panel renders it as plain quoted
        # text below the args. The gateway owns producing it — here the fake
        # gateway supplies it directly; the assertion is the panel surfaces it.
        ipc("send", "approve-ctx:appr-ctx")
        if not wait_until(
            lambda: ipc("approvalState", "appr-ctx") == "pending", timeout_s=15
        ):
            die("preview-context approval bubble never appeared pending")
        if ipc("approvalTool", "appr-ctx") != "signal_send":
            die(f"context approval tool mismatch: {ipc('approvalTool', 'appr-ctx')!r}")
        ctx = ipc("approvalContext", "appr-ctx")
        if "Alice" not in ctx or "similar to" not in ctx:
            die(f"panel did not surface the preview context: {ctx!r}")
        ipc("respond", "appr-ctx", "once")

        # Fail-closed (decision 5): when the gateway's preview errors it raises
        # NO approval_request (the child gets a tool error instead). The panel
        # must never render a bubble the gateway did not send.
        ipc("send", "fail-closed:appr-fc")
        if wait_until(
            lambda: ipc("approvalState", "appr-fc") != "", timeout_s=3
        ):
            die("panel rendered an approval bubble for a fail-closed call")

        sys.stderr.write(
            "PASS: approval_request rendered (+ preview context, fail-closed) "
            "and once/session/deny replied over WS\n"
        )
    finally:
        qs.stop()
        reap(daemon)


if __name__ == "__main__":
    main()
