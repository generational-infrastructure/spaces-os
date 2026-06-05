#!/usr/bin/env python3
"""NComboBox model-name truncation-tooltip component test.

The model dropdown shows a per-row tooltip with the full model name only
when that row's label elides (a trailing "…"). The tooltip is wired as:

    ToolTip.visible: delegateLabel.truncated && delegateItem.hovered
    ToolTip.text:    delegateItem.fullName

A real hover and the windowed Popup can't be synthesised headlessly, so
this drives the real delegate Component directly and checks the two
ingredients the tooltip is built from:

  1. A long label in a NARROW row elides   -> truncated == True
     (so the gate `truncated && hovered` can fire), and `fullName`
     still carries the complete, untruncated string the tip renders.
  2. The SAME label in a WIDE row fits      -> truncated == False
     (so the tooltip stays suppressed when nothing is hidden).

Headless quickshell, offscreen platform. No pi, no LLM. ~3-5s.
"""

import json
import os
import shutil
import subprocess
import sys
import time

# A model label long enough to overflow a narrow row but fit a wide one.
LONG_NAME = "[openrouter] anthropic/claude-3.5-sonnet-20241022-instruct-preview"
NARROW_W = 90
WIDE_W = 1200


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
    # Stage the real Commons (Style/Color/Settings singletons) and Widgets
    # (NComboBox + NText) so the test exercises the exact components the
    # panel ships, not a stand-in.
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

    def probe_at(width: int) -> dict:
        ipc_call(qs_bin, shell_qml, env, "configure", LONG_NAME, str(width))
        if not wait_until(
            lambda: ipc_call(qs_bin, shell_qml, env, "ready") == "1",
            timeout_s=10,
        ):
            die(f"delegate never laid out at width {width}")
        return json.loads(ipc_call(qs_bin, shell_qml, env, "probe"))

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

        # (1) Narrow row: the long label overflows, so it elides and the
        # tooltip gate can fire — while the tip still carries the full name.
        narrow = probe_at(NARROW_W)
        if narrow.get("fullName") != LONG_NAME:
            die(f"narrow: fullName lost the untruncated label, got {narrow!r}")
        if narrow.get("truncated") is not True:
            die(f"narrow: expected truncated label at {NARROW_W}px, got {narrow!r}")

        # (2) Wide row: the same label fits, so nothing is hidden and the
        # tooltip stays suppressed (truncated False).
        wide = probe_at(WIDE_W)
        if wide.get("fullName") != LONG_NAME:
            die(f"wide: fullName lost the untruncated label, got {wide!r}")
        if wide.get("truncated") is not False:
            die(f"wide: expected no elision at {WIDE_W}px, got {wide!r}")

        sys.stderr.write(
            "PASS: combo row elides + exposes full name only when overflowing\n"
        )
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
