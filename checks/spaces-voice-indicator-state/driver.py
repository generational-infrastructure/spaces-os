#!/usr/bin/env python3
"""Spaces Voice Indicator — headless reactivity component test.

Drives the plugin's Main.qml FileView service the same way voxtype's
daemon does: by writing the bare lifecycle word to
$XDG_RUNTIME_DIR/voxtype/state (truncate-in-place, mirroring voxtype's
std::fs::write) and reading voiceState back over the quickshell ipc CLI.

Asserts the seven-step contract the bar feature relies on:

  1. no file yet                 → "down"   (onLoadFailed)
  2. write "idle"                → "idle"
  3. write "recording"           → "recording"
  4. write "transcribing"        → "transcribing"
  5. write "streaming"           → "streaming"  (service exposes the raw
                                    word; the widget maps it to recording)
  6. write "" (empty)            → unchanged ("streaming")  keep-previous
  7. remove the file             → "down"   (onLoadFailed)

This proves reactive idle→recording→transcribing on fs::write, the
keep-previous rule on a transient empty read, and onLoadFailed→down.

Headless quickshell, offscreen platform. No voxtype, no compositor. ~3-10s.
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
    # `Main {}` component resolves from the same directory.
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
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:voice", *args]
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
    # voxtype's runtime_dir() == $XDG_RUNTIME_DIR/voxtype; the daemon
    # writes its state file there. Pre-create it; the daemon would.
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

    def read_state() -> str:
        return ipc_call(qs_bin, shell_qml, env, "state")

    def write_state(word: str) -> None:
        # Truncate-in-place, mirroring voxtype's std::fs::write.
        with open(state_file, "w") as f:
            f.write(word)

    def expect(word: str, label: str) -> None:
        if not wait_until(lambda: read_state() == word, timeout_s=8):
            die(f"{label}: expected {word!r}, got {read_state()!r}")

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:voice" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:voice IPC target")

        # (1) No file yet → the startup reload hits onLoadFailed → "down".
        expect("down", "step1 no-file")

        # (2)-(5) Each transition voxtype would write must light up
        # reactively via the FileView watch.
        write_state("idle")
        expect("idle", "step2 idle")

        write_state("recording")
        expect("recording", "step3 recording")

        write_state("transcribing")
        expect("transcribing", "step4 transcribing")

        write_state("streaming")
        expect("streaming", "step5 streaming")

        # (6) Empty/partial read must keep the previous value, not blank
        # the bar. Settle, then assert it is still "streaming".
        write_state("")
        time.sleep(1.0)
        s = read_state()
        if s != "streaming":
            die(f"step6 empty keep-previous: expected 'streaming', got {s!r}")

        # (7) Daemon shutdown removes the file → onLoadFailed → "down".
        os.remove(state_file)
        expect("down", "step7 removed")

        sys.stderr.write("PASS: voice indicator reactive lifecycle holds\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
