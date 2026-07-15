#!/usr/bin/env python3
"""Contract check for the standalone confirm popup
(programs/spaces-integration-confirm, docs/agent-integrations-generic-mcp-design.md
§2/§3).

Boots the REAL popup shell.qml with a request in SPACES_CONFIRM_REQUEST and a
path in SPACES_CONFIRM_VERDICT_FILE, then for each verdict token —
once | session | deny — drives decide() over IPC (exactly what a button click
does) and asserts the popup wrote that token to the verdict file. The first
instance also asserts the popup parsed the request env and surfaces the tool,
the concrete args (per-field via argFields()), and the untrusted preview
context; a nested-args instance asserts nested objects render as pretty JSON.

The popup is a Quickshell PanelWindow on the wlr layer-shell Overlay layer, so
its backend only loads under a real wayland platform (QT_QPA_PLATFORM=offscreen
has NO PanelWindow backend). We therefore boot a throwaway headless wlroots
compositor (sway --headless) under the check's XDG_RUNTIME_DIR and run quickshell
as a wayland client of it. Rendering fidelity is irrelevant — we only need the
backend to instantiate so the IpcHandler binds. No gateway, no VM. ~seconds.
"""

import json
import os
import re
import sys
from pathlib import Path

from qs_harness import Quickshell, fail, qs_env, reap, spawn, stage_shell, wait_until

REQUEST = {
    "integration": "signal",
    "tool": "send",
    "toolName": "signal_send",
    "args": {"recipient": "+15550001", "body": "hi bob"},
    "context": "To: Bob\nhi bob",
}

# A second fixture exercising nested args: the popup must render a nested
# object as pretty-printed JSON inside its own per-field well (FILTERS),
# while scalars stay flat (LIMIT).
REQUEST_NESTED = {
    "integration": "signal",
    "tool": "search",
    "toolName": "signal_search",
    "args": {"filters": {"unread": True}, "limit": 5},
    "context": "",
}


def start_compositor(work_dir):
    """Boot a throwaway headless wlroots compositor (sway) under the check's
    XDG_RUNTIME_DIR and return (proc, wayland_display_name).

    quickshell's PanelWindow / WlrLayershell backend only loads under a real
    wayland platform, so the popup can't boot on QT_QPA_PLATFORM=offscreen; a
    headless sway provides the wlr-layer-shell the popup needs. Software
    rendering (WLR_RENDERER=pixman + Qt's software scenegraph on the client)
    keeps it GPU-free for the nix build sandbox.
    """
    xdg = os.path.join(work_dir, "xdg")
    os.makedirs(xdg, exist_ok=True)
    os.chmod(xdg, 0o700)
    cfg = os.path.join(work_dir, "sway.cfg")
    # Minimal config: no bar, no autostart. sway still emits a benign
    # "Could not find config for output HEADLESS-1" line — harmless.
    Path(cfg).write_text("exec true\n")
    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg,
        "WLR_BACKENDS": "headless",
        "WLR_LIBINPUT_NO_DEVICES": "1",
        "WLR_RENDERER": "pixman",
    }
    proc = spawn(["sway", "-c", cfg], work_dir, "sway.log", env=env)

    def _sock():
        for n in os.listdir(xdg):
            if re.fullmatch(r"wayland-\d+", n):
                return n
        return None

    if not wait_until(lambda: _sock() is not None, timeout_s=30):
        log = Path(work_dir, "sway.log")
        sys.stderr.write(log.read_text() if log.is_file() else "<no sway.log>")
        reap(proc)
        fail("headless sway never created a wayland socket")
    return proc, _sock()


def main():
    if len(sys.argv) < 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)

    sway_proc, wl = start_compositor(work_dir)
    # Every quickshell instance runs as a wayland client of the throwaway sway;
    # the software scenegraph keeps the client GPU-free too.
    wl_env = {
        "QT_QPA_PLATFORM": "wayland",
        "WAYLAND_DISPLAY": wl,
        "QT_QUICK_BACKEND": "software",
    }
    try:
        for idx, verdict in enumerate(("once", "session", "deny")):
            vfile = os.path.join(work_dir, f"verdict-{verdict}")
            env = qs_env(
                work_dir,
                {
                    **wl_env,
                    "SPACES_CONFIRM_REQUEST": json.dumps(REQUEST),
                    "SPACES_CONFIRM_VERDICT_FILE": vfile,
                },
            )
            qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="confirm")
            qs.start()
            try:
                qs.wait_ipc_ready()

                # First instance: the popup parsed the request and surfaces
                # exactly what the gateway will forward on approval.
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

                    # Per-field surface: argFields() returns the {label,value}
                    # rows the popup renders — labels are the uppercased arg
                    # keys, values the exact scalar text. Two top-level keys.
                    fields = json.loads(qs.ipc("argFields"))
                    by_label = {f["label"]: f["value"] for f in fields}
                    if by_label != {"RECIPIENT": "+15550001", "BODY": "hi bob"}:
                        qs.die(f"argFields mismatch for scalar args: {fields!r}")

                qs.ipc("decide", verdict)
                if not wait_until(
                    lambda vf=vfile, v=verdict: (
                        Path(vf).is_file() and Path(vf).read_text() == v
                    ),
                    timeout_s=15,
                ):
                    got = (
                        Path(vfile).read_text() if Path(vfile).is_file() else "<absent>"
                    )
                    qs.die(f"verdict {verdict!r} never written; got {got!r}")
                # The popup must self-exit after deciding (Qt.quit); otherwise
                # the gateway's runner blocks until timeout and falls back to
                # deny.
                if not wait_until(lambda q=qs: q.proc.poll() is not None, timeout_s=10):
                    qs.die(f"popup did not self-exit after decide({verdict!r})")
            finally:
                qs.stop()

        # A second instance with nested args: the nested object must render as
        # pretty-printed JSON under its uppercased key, scalars stay flat.
        env = qs_env(
            work_dir,
            {
                **wl_env,
                "SPACES_CONFIRM_REQUEST": json.dumps(REQUEST_NESTED),
                "SPACES_CONFIRM_VERDICT_FILE": os.path.join(work_dir, "verdict-nested"),
            },
        )
        qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="confirm")
        qs.start()
        try:
            qs.wait_ipc_ready()
            fields = json.loads(qs.ipc("argFields"))
            by_label = {f["label"]: f["value"] for f in fields}
            if by_label.get("LIMIT") != "5":
                qs.die(f"argFields nested scalar mismatch: {fields!r}")
            filters = by_label.get("FILTERS", "")
            if json.loads(filters) != {"unread": True} or "\n" not in filters:
                qs.die(f"FILTERS did not render as pretty JSON: {filters!r}")
        finally:
            qs.stop()

        print("PASS: confirm popup surfaces the request and writes each verdict")
    finally:
        reap(sway_proc)


main()
