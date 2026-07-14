#!/usr/bin/env python3
"""Contract check for the standalone confirm popup
(programs/spaces-integration-confirm, docs/agent-integrations-generic-mcp-design.md
§2/§3).

Boots the REAL popup shell.qml headless with a request in
SPACES_CONFIRM_REQUEST and a path in SPACES_CONFIRM_VERDICT_FILE, then for each
verdict token — once | session | deny — drives decide() over IPC (exactly what a
button click does) and asserts the popup wrote that token to the verdict file.
The first instance also asserts the popup parsed the request env and surfaces the
tool, the concrete args, and the untrusted preview context. No compositor, no
gateway, no VM. ~seconds.
"""

import json
import os
import sys
from pathlib import Path

from qs_harness import Quickshell, fail, qs_env, stage_shell, wait_until

REQUEST = {
    "integration": "signal",
    "tool": "send",
    "toolName": "signal_send",
    "args": {"recipient": "+15550001", "body": "hi bob"},
    "context": "To: Bob\nhi bob",
}


def main():
    if len(sys.argv) < 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)

    for idx, verdict in enumerate(("once", "session", "deny")):
        vfile = os.path.join(work_dir, f"verdict-{verdict}")
        env = qs_env(
            work_dir,
            {
                "SPACES_CONFIRM_REQUEST": json.dumps(REQUEST),
                "SPACES_CONFIRM_VERDICT_FILE": vfile,
            },
        )
        qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="confirm")
        qs.start()
        try:
            qs.wait_ipc_ready()

            # First instance: the popup parsed the request and surfaces exactly
            # what the gateway will forward on approval.
            if idx == 0:
                tn = qs.ipc("toolName")
                if tn != "signal_send":
                    qs.die(f"toolName mismatch: {tn!r}")
                args = qs.ipc("argsText")
                if "+15550001" not in args or "hi bob" not in args:
                    qs.die(f"argsText did not surface the call args: {args!r}")
                ctx = qs.ipc("context")
                if ctx != "To: Bob\nhi bob":
                    qs.die(f"context mismatch: {ctx!r}")

            qs.ipc("decide", verdict)
            if not wait_until(
                lambda vf=vfile, v=verdict: (
                    Path(vf).is_file() and Path(vf).read_text() == v
                ),
                timeout_s=15,
            ):
                got = Path(vfile).read_text() if Path(vfile).is_file() else "<absent>"
                qs.die(f"verdict {verdict!r} never written; got {got!r}")
            # The popup must self-exit after deciding (Qt.quit); otherwise the
            # gateway's runner blocks until timeout and falls back to deny.
            if not wait_until(lambda q=qs: q.proc.poll() is not None, timeout_s=10):
                qs.die(f"popup did not self-exit after decide({verdict!r})")
        finally:
            qs.stop()

    print("PASS: confirm popup surfaces the request and writes each verdict")


main()
