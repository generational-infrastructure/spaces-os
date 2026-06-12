#!/usr/bin/env python3
"""Host-directive launch contract test.

Proves backend.launchBackground(prompt, {executor}) pins the launched
session to the named executor and refuses an unknown id rather than
silently launching on the default. No pi worker, no LLM: the executor
field is stamped synchronously by newSession, so the contract is a pure
data + control-flow assertion driven over test-only IPC verbs that call
the SAME backend function the quick-launch bar does.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

TARGET = "test:quick-launch-host"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Mirror the whole pi-chat tree, then drop in our test shell.qml."""
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


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def die(msg):
        p = os.path.join(work_dir, "qs.log")
        if os.path.isfile(p):
            sys.stderr.write("\n== qs.log ==\n")
            sys.stderr.write(open(p, errors="replace").read()[-6000:])
        fail(msg)

    def call(*args: str, check: bool = True) -> str:
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", TARGET, *args]
        out = subprocess.run(
            cmd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20
        )
        if check and out.returncode != 0:
            raise RuntimeError(
                f"ipc {args} failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return out.stdout.strip()

    def executor_of(sid: str) -> str | None:
        for s in json.loads(call("dumpSessions")):
            if s["id"] == sid:
                return s["executor"]
        return None

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and TARGET in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the host IPC target")

        # Seed the executor inventory; confirm it took.
        seeded = json.loads(call("seedExecutors"))
        if seeded != ["kiwi", "traube"]:
            die(f"executor seed failed: {seeded!r}")
        # Two executors, no explicit default → the first configured
        # executor is the default. ("" is only the transient marker for
        # an unloaded/empty inventory; it no longer means "local pi".)
        if call("defaultExecutorId") != "kiwi":
            die(f"unexpected defaultExecutorId {call('defaultExecutorId')!r}")

        # (a) valid id pins the session.
        before = int(call("sessionCount"))
        sid = call("launchHost", "summarize logs", "kiwi")
        if not sid:
            die("launchHost returned no session id for a valid executor")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            die(f"valid launch created no session (count {call('sessionCount')})")
        if executor_of(sid) != "kiwi":
            die(f"session executor {executor_of(sid)!r}, want 'kiwi'")

        # (b) unknown id is REFUSED — no session, default not used.
        before = int(call("sessionCount"))
        bad = call("launchHost", "diagnose outage", "ghost")
        if bad != "":
            die(f"unknown executor launch returned id {bad!r}; expected refusal")
        time.sleep(0.5)
        if int(call("sessionCount")) != before:
            die("unknown executor launch created a session (should be refused)")

        # (c) a second valid id pins exactly (no cross-talk with the first).
        before = int(call("sessionCount"))
        sid2 = call("launchHost", "tidy up", "traube")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            die("second valid launch created no session")
        if executor_of(sid2) != "traube":
            die(f"second session executor {executor_of(sid2)!r}, want 'traube'")

        # (d) omitting the executor pins the session to the default
        # executor (the first configured one) at mint time.
        before = int(call("sessionCount"))
        sid3 = call("launchPlain", "no host here")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            die("plain launch created no session")
        if executor_of(sid3) != "kiwi":
            die(f"plain session executor {executor_of(sid3)!r}, want 'kiwi' (default)")

        print("PASS")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
