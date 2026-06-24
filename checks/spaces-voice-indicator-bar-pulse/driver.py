#!/usr/bin/env python3
"""Spaces Voice Indicator — bar-pulse activation test.

Drives two copies of the plugin's Main.qml service (one with the feature
at its default, one opted out) by writing voxtype's lifecycle word to
$XDG_RUNTIME_DIR/voxtype/state, exactly as the daemon does, and reading
the pulse-driving state back over the quickshell ipc CLI.

Asserts the contract the whole-bar ambient cue relies on:

  1. no file yet      → not recording → pulse OFF (both)
  2. write "idle"     → pulse OFF; default enable flag is ON
  3. write "recording"→ pulse ON for the default host, OFF for the
                        opted-out host (one signal, two policies)
  4. write "streaming"→ pulse ON (live capture also pulses)
  5. write "transcribing" → pulse OFF (capture finished)
  6. remove the file  → pulse OFF (daemon down)

This proves the pulse reuses voxtype's voiceState, activates on
recording/streaming and only then, and that barPulse=false suppresses it
without touching the underlying state. Headless quickshell, offscreen
platform. No voxtype, no compositor. ~3-10s.
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
    # Main.qml is the unit under test; stage it next to shell.qml so the
    # `Main {}` component resolves from the same directory. BarPulse.qml
    # (the layer-shell overlay) is deliberately NOT staged: neither host
    # here arms its LazyLoader, so the noctalia qs.Commons / layer-shell
    # surface is never exercised — this test pins Main.qml's pulse LOGIC.
    shutil.copy2(
        os.path.join(plugin_dir, "Main.qml"), os.path.join(shell_root, "Main.qml")
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
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:voicepulse", *args]
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
    voxtype_dir = os.path.join(xdg_runtime, "voxtype")
    os.makedirs(voxtype_dir, exist_ok=True)
    state_file = os.path.join(voxtype_dir, "state")

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

    def call(*args: str) -> str:
        return ipc_call(qs_bin, shell_qml, env, *args)

    def write_state(word: str) -> None:
        with open(state_file, "w") as f:
            f.write(word)

    def expect(fn: str, want: str, label: str) -> None:
        if not wait_until(lambda: call(fn) == want, timeout_s=8):
            die(f"{label}: {fn} expected {want!r}, got {call(fn)!r}")

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:voicepulse" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:voicepulse IPC target")

        # The opt-out is a static policy; it must read false the whole time.
        if call("enabledDisabled") != "false":
            die("barPulse=false host must report the feature disabled")

        # (1) No file yet → not recording → pulse off, both hosts.
        expect("stateDefault", "down", "step1 no-file")
        expect("pulseDefault", "false", "step1 default pulse off when down")
        expect("pulseDisabled", "false", "step1 disabled pulse off when down")

        # (2) idle → pulse off, but the feature is enabled by default.
        write_state("idle")
        expect("stateDefault", "idle", "step2 idle")
        expect("pulseDefault", "false", "step2 no pulse while idle")
        expect("enabledDefault", "true", "step2 default barPulse enabled")

        # (3) recording → default host pulses; opted-out host does NOT,
        # even though it sees the very same recording state.
        write_state("recording")
        expect("pulseDefault", "true", "step3 default pulses on recording")
        expect("pulseDisabled", "false", "step3 opt-out suppresses the pulse")

        # (4) streaming is live capture too → pulse on.
        write_state("streaming")
        expect("pulseDefault", "true", "step4 default pulses on streaming")

        # (5) transcribing → capture done → pulse off.
        write_state("transcribing")
        expect("pulseDefault", "false", "step5 no pulse while transcribing")

        # (6) daemon down (file removed) → pulse off.
        os.remove(state_file)
        expect("stateDefault", "down", "step6 removed")
        expect("pulseDefault", "false", "step6 no pulse when down")

        sys.stderr.write("PASS: bar-pulse activation contract holds\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
