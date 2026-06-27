#!/usr/bin/env python3
"""Component test for the chat history's scroll behaviour (issue #28).

The chat history is a BottomToTop ListView whose model is the reversed
`chat.messages` array. Every streaming token reassigns that array and
regrows the newest bubble; the model-driven relayout then re-anchors the
view to the newest message (the visual bottom). With nothing holding the
position that snap yanks a reader who had scrolled up back to the bottom
on *every token* — so you cannot read scrollback while the agent types.

This guards both halves of the fix:

  * REGRESSION — scrolled up, then the agent streams: the view must stay
    put (Qt's `atYEnd` stays false) and hold the same messages on screen
    (the gap from the top of content, contentY - originY, is invariant).
  * FOLLOW — pinned to the newest message: streaming must keep it pinned
    (`atYEnd` stays true), and a message arriving while scrolled up must
    be appended without snapping down.

Headless quickshell, offscreen platform. No compositor, no pi, no LLM.
"""

import os
import shutil
import subprocess
import sys
import time

TARGET = "scroll"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Mirror the whole pi-chat plugin tree, then drop in our shell.qml.

    Panel.qml pulls in most of the plugin (Bubble, NComboBox, the i18n
    bundle, MsgText.js, …), so we copy the tree and overwrite the entry
    shell with the harness.
    """
    shell_root = os.path.join(work_dir, "shell")
    shutil.copytree(plugin_dir, shell_root, dirs_exist_ok=True)
    for root, _dirs, files in os.walk(shell_root):
        os.chmod(root, 0o755)
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o644)
            except OSError:
                pass
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
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", TARGET, *args]
        out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(
                f"qs ipc call {args} failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return out.stdout.strip()

    def num(name: str) -> float:
        v = call(name)
        try:
            return float(v)
        except ValueError as e:
            die(f"{name} returned non-numeric {v!r}: {e}")

    def settle():
        # Let the flick animation / Qt.callLater restore run to completion.
        wait_until(lambda: call("moving") == "false", timeout_s=5)
        time.sleep(0.2)

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "call", TARGET, "count"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test IPC target")

        # ── seed a tall, scrollable history ─────────────────────────────
        call("populate", "40")
        time.sleep(0.6)
        if call("count") != "40":
            die(f"history count={call('count')!r}, expected 40 after populate")

        # ── FOLLOW: a fresh open lands pinned to the newest message ─────
        if call("atYEnd") != "true":
            die(
                "after populate the view is not pinned to the newest message (atYEnd != true)"
            )
        # Stream while pinned — must keep following the newest bubble.
        for _ in range(8):
            call("streamDelta")
            time.sleep(0.08)
        settle()
        if call("atYEnd") != "true":
            die(
                "streaming unpinned a reader who was at the bottom (atYEnd flipped to false)"
            )
        sys.stderr.write(
            "PASS: streaming keeps a bottom-pinned reader following the newest message\n"
        )

        # ── REGRESSION: scroll up, then stream — must not be yanked ─────
        # Flick toward older messages until we're genuinely off the bottom.
        for _ in range(15):
            call("flick", "4000")
            settle()
            if call("atYEnd") == "false":
                break
        if call("atYEnd") != "false":
            die("could not scroll up off the bottom with flick (test setup)")

        y0 = num("contentY")
        o0 = num("originY")
        gap0 = y0 - o0  # distance from the top of content; invariant we defend

        for _ in range(10):
            call("streamDelta")
            time.sleep(0.08)
        settle()

        if call("atYEnd") == "true":
            die(
                "streaming yanked the scrolled-up reader back to the bottom "
                "(atYEnd snapped to true) — issue #28 regression"
            )
        y1 = num("contentY")
        o1 = num("originY")
        gap1 = y1 - o1
        drift = abs(gap1 - gap0)
        if drift > 4.0:
            die(
                f"scroll position drifted by {drift:.1f}px while streaming "
                f"(gap {gap0:.1f} -> {gap1:.1f}); scrollback not held steady"
            )
        sys.stderr.write(
            f"PASS: streaming holds the scrolled-up view (atYEnd=false, drift={drift:.1f}px)\n"
        )

        # ── APPEND: a new message while scrolled up never snaps ─────────
        before = int(float(call("count")))
        call("appendMsg")
        time.sleep(0.3)
        settle()
        if call("atYEnd") == "true":
            die("an appended message yanked the scrolled-up reader to the bottom")
        after = int(float(call("count")))
        if after != before + 1:
            die(
                f"appended message did not reach history model (count {before} -> {after})"
            )
        sys.stderr.write(
            f"PASS: a message arriving while scrolled up appends ({before} -> {after}) and holds position\n"
        )
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
