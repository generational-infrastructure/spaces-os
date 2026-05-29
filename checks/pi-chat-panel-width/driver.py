#!/usr/bin/env python3
"""Component test for Panel.qml's surface sizing.

Regression guard for the chat panel's width. shell.qml asks the
Quickshell PanelWindow for `implicitWidth: 480`. QQuickWindow takes
its implicit size from its contentItem, so any `implicitWidth` the
embedded Panel sets propagates upward and replaces the shell's 480.
Panel.qml used to carry a `contentPreferredWidth: 1000` left over
from the noctalia SmartPanel host and bind `implicitWidth` to it;
that forced the wayland surface to ~1000 px, which on a typical
laptop pushes the header buttons and every chat bubble off the
right edge of the screen.

Panel.qml MUST NOT propagate an implicit width larger than the
window it's embedded in.

Headless quickshell, offscreen platform. No compositor, no pi, no
LLM. ~3s.
"""

import os
import shutil
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Stage the entire pi-chat plugin tree alongside the test shell.

    Panel.qml depends on most of the plugin (Bubble, NComboBox,
    SignalConfirm, the i18n bundle, MsgText.js, …) so we mirror the
    whole tree and then drop in our own shell.qml at the root.
    """
    shell_root = os.path.join(work_dir, "shell")
    shutil.copytree(plugin_dir, shell_root, dirs_exist_ok=True)
    # Files copied from the nix store come in read-only; mtime touch
    # below (and shell.qml overwrite right after) need them writable.
    for root, _dirs, files in os.walk(shell_root):
        os.chmod(root, 0o755)
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o644)
            except OSError:
                pass
    # Replace shell.qml with the harness — the real one wires up
    # PiChatBackend, IpcHandler verbs, etc., none of which the
    # sizing test needs.
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


def ipc_call(
    qs_bin: str, shell_qml: str, env: dict, *args: str, target: str = "test:panel-width"
) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", target, *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def dump_logs():
        for label, name in [
            ("qs.stdout", "qs.stdout.log"),
            ("qs.stderr", "qs.stderr.log"),
        ]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    def die(msg):
        dump_logs()
        fail(msg)

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return (
                r.returncode == 0
                and "test:panel-width" in r.stdout
                and "test:signal-banner" in r.stdout
            )

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test IPC targets")

        # Sanity: the window honoured shell.qml's implicitWidth of 480.
        # If this drifts the rest of the assertions become meaningless.
        win_implicit = ipc_call(qs_bin, shell_qml, env, "winImplicitWidth")
        if win_implicit != "480":
            die(
                f"test harness window.implicitWidth={win_implicit}, expected 480 "
                "— shell.qml binding broken"
            )

        # THE REGRESSION: Panel.qml advertised implicitWidth = 1000
        # (the noctalia SmartPanel `contentPreferredWidth`), which the
        # QQuickWindow contentItem propagates to the wayland surface
        # request. On a typical-width screen the panel ends up wider
        # than the layer-shell output and content clips off the right
        # edge.
        try:
            implicit = float(ipc_call(qs_bin, shell_qml, env, "panelImplicitWidth"))
        except ValueError as e:
            die(f"panelImplicitWidth IPC returned non-numeric value: {e}")

        if implicit > 480:
            die(
                f"Panel.implicitWidth={implicit:.0f}px, exceeds the host window's "
                "480px — surface will overflow the screen edge"
            )

        # Second-order check: the laid-out width must also fit, which
        # confirms that anchors.fill is doing its job once the implicit
        # is sane. Allow a small tolerance for window-frame rounding.
        try:
            laid = float(ipc_call(qs_bin, shell_qml, env, "panelWidth"))
        except ValueError as e:
            die(f"panelWidth IPC returned non-numeric value: {e}")

        if laid > 480:
            die(
                f"Panel.width={laid:.0f}px, exceeds the 480px host window — "
                "anchors.fill not respected"
            )

        sys.stderr.write(
            f"PASS: panel implicitWidth={implicit:.0f} width={laid:.0f} (both <= 480)\n"
        )

        # THE REGRESSION: the pending-Signal approval banner is owned by
        # PiChatBackend (signalPendingSends), not by the active session.
        # When the banner binds to `chat` (= backend.chat) instead of
        # `backend`, the cards never render and the user can't approve a
        # send the agent enqueued. The stub backend in shell.qml exposes
        # exactly one pending send off the backend; the banner must see it.
        count = ipc_call(
            qs_bin, shell_qml, env, "bannerCount", target="test:signal-banner"
        )
        if count == "no-banner":
            die("signal banner Rectangle not found in the Panel tree")
        if count != "1":
            die(
                f"signal banner items={count}, expected 1 — banner not reading "
                "backend.signalPendingSends"
            )
        visible = ipc_call(
            qs_bin, shell_qml, env, "bannerVisible", target="test:signal-banner"
        )
        if visible != "true":
            die(
                f"signal banner visible={visible!r}, expected 'true' — "
                "pending send enqueued but no approval card shown"
            )
        sys.stderr.write("PASS: signal banner renders backend pending sends\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
