#!/usr/bin/env python3
"""Component test for the NComboBox dropdown popup.

Regression guard for the model selector. The popup's height is
derived from its content ListView via
`Math.min(contentItem.implicitHeight, popupHeight)`. A bare ListView
reports implicitHeight 0, which collapses the Popup to zero height:
the dropdown "opens" but is invisible, so clicking the model selector
appears to do nothing. The content ListView MUST set
`implicitHeight: contentHeight` (matching Qt's own ComboBox popup) so
the popup gets a real height.

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
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    # Stage the real Commons + Widgets so the test exercises the
    # actual NComboBox/NText/Style/Color/Settings the panel ships.
    for sub in ("Commons", "Widgets"):
        shutil.copytree(
            os.path.join(plugin_dir, sub),
            os.path.join(shell_root, sub),
            dirs_exist_ok=True,
        )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:combo", *args]
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
            return r.returncode == 0 and "test:combo" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:combo IPC target")

        # Model wired up: 3 items, currentKey preselects "two".
        count = ipc_call(qs_bin, shell_qml, env, "count")
        if count != "3":
            die(f"combo did not load the 3-item model (count={count})")

        # Popup starts hidden.
        if ipc_call(qs_bin, shell_qml, env, "popupVisible") != "false":
            die("popup should start hidden")

        # Open the dropdown.
        ipc_call(qs_bin, shell_qml, env, "openPopup")
        if not wait_until(
            lambda: ipc_call(qs_bin, shell_qml, env, "popupVisible") == "true",
            timeout_s=5,
        ):
            die("popup never became visible after open()")

        # THE REGRESSION: an opened popup must have a real height. A
        # bare-ListView contentItem yields implicitHeight 0, so the
        # dropdown is invisible even though it reports "visible".
        def has_height():
            try:
                return float(ipc_call(qs_bin, shell_qml, env, "popupHeight")) > 0
            except ValueError:
                return False

        if not wait_until(has_height, timeout_s=5):
            ch = ipc_call(qs_bin, shell_qml, env, "contentHeight")
            ih = ipc_call(qs_bin, shell_qml, env, "popupImplicitHeight")
            die(
                f"opened popup has zero height (implicitHeight={ih}, "
                f"contentHeight={ch}) — dropdown invisible"
            )

        sys.stderr.write("PASS: combo popup opens with non-zero height\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
