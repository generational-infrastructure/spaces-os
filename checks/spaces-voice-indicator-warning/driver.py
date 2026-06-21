#!/usr/bin/env python3
"""Spaces Voice Indicator — WARNING visual-mapping test.

Loads the plugin's real BarWidget.qml in a headless quickshell against stub
noctalia singletons, drives the service state over IPC, and asserts the
glyph / colour / tooltip / visibility the bar derives — the colour-and-tooltip
contract that agent-vm would otherwise have to screenshot.

Asserts, against noctalia's default dark palette:

  idle                       → dim mic (mOnSurfaceVariant), tooltip-idle, shown
  idle + qualityWarning      → caution mic (mTertiary), tooltip-no-speech, shown
                               — and distinct from BOTH recording and transcribing
  recording                  → red mic (mError), tooltip-recording
  transcribing               → amber loader-2 (mPrimary), tooltip-transcribing
  hideWhenIdle + idle        → hidden …
  hideWhenIdle + warning     → … but the warning forces it visible again

Headless quickshell, offscreen platform. No noctalia, no compositor. ~3-10s.
"""

import os
import shutil
import subprocess
import sys
import time

# Noctalia default-dark palette (mirrors the stub Color singleton).
C_ERROR = "fd4663"  # recording
C_PRIMARY = "fff59b"  # transcribing
C_TERTIARY = "9bfece"  # no-speech warning
C_IDLE = "7c80b4"  # idle (mOnSurfaceVariant)


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
    # shell.qml + the unit under test resolve `BarWidget {}` from this dir.
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    shutil.copy2(
        os.path.join(plugin_dir, "BarWidget.qml"),
        os.path.join(shell_root, "BarWidget.qml"),
    )
    # Stub noctalia subtree under the shell root so `import qs.Commons` etc.
    # resolve via quickshell's `qs` = shell-root convention.
    for sub in ("Commons", "Services", "Widgets"):
        shutil.copytree(
            os.path.join(test_dir, "stub", sub),
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
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:bar", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": work_dir,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_stdout, stderr=qs_stderr
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

    def call(*args: str) -> str:
        return ipc_call(qs_bin, shell_qml, env, *args)

    def set_voice(s: str):
        call("setVoice", s)

    def set_warning(w: str):
        call("setWarning", w)

    def set_hide(b: str):
        call("setHideWhenIdle", b)

    def color() -> str:
        return call("color").lower()

    def expect_color(hex6: str, label: str):
        got = color()
        if hex6 not in got:
            die(f"{label}: expected colour ~#{hex6}, got {got!r}")

    def expect(fn, want: str, label: str):
        if not wait_until(lambda: fn() == want, timeout_s=6):
            die(f"{label}: expected {want!r}, got {fn()!r}")

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:bar" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:bar IPC target")

        # Idle baseline: dim mic, idle tooltip, visible.
        set_voice("idle")
        set_warning("")
        expect(lambda: call("glyph"), "microphone", "idle glyph")
        expect(lambda: call("tooltip"), "voice.tooltip-idle", "idle tooltip")
        expect(lambda: call("shown"), "1", "idle shown")
        expect_color(C_IDLE, "idle colour")

        # No-speech warning on the idle glyph: caution tone + matching tooltip.
        set_warning("no_speech")
        expect(lambda: call("tooltip"), "voice.tooltip-no-speech", "warning tooltip")
        expect(lambda: call("glyph"), "microphone", "warning glyph stays mic")
        expect(lambda: call("shown"), "1", "warning shown")
        expect_color(C_TERTIARY, "warning colour is mTertiary")
        # The caution tone MUST be distinct from both busy states.
        warn_c = color()
        if C_ERROR in warn_c or C_PRIMARY in warn_c:
            die(
                f"warning colour must differ from recording/transcribing, got {warn_c!r}"
            )

        # Recording: red mic.
        set_warning("")
        set_voice("recording")
        expect(lambda: call("tooltip"), "voice.tooltip-recording", "recording tooltip")
        expect_color(C_ERROR, "recording colour")

        # Transcribing: amber spinner glyph.
        set_voice("transcribing")
        expect(lambda: call("glyph"), "loader-2", "transcribing glyph")
        expect(
            lambda: call("tooltip"),
            "voice.tooltip-transcribing",
            "transcribing tooltip",
        )
        expect_color(C_PRIMARY, "transcribing colour")

        # hideWhenIdle: idle is hidden …
        set_voice("idle")
        set_warning("")
        set_hide("true")
        expect(lambda: call("shown"), "0", "hideWhenIdle hides idle")
        # … but a pending warning forces the glyph back visible.
        set_warning("no_speech")
        expect(lambda: call("shown"), "1", "warning overrides hideWhenIdle")
        expect_color(C_TERTIARY, "warning colour under hideWhenIdle")

        sys.stderr.write("PASS: voice indicator warning visual mapping holds\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
