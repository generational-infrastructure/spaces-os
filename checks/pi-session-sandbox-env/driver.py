#!/usr/bin/env python3
"""Sandbox env-forwarding contract for PiSession.

Drives PiSession through quickshell IPC and asserts the resulting
`systemd-run --user` argv contains `--setenv=PATH=<expected>`. This
guards against a regression of the skill-CLI ENOENT: without explicit
PATH forwarding, transient user units inherit only the user@.service
PATH (coreutils + systemd's bin on NixOS), and every skill CLI shelled
out by bare name from SKILL.md is unreachable on compositors that
don't run `systemctl --user import-environment` at session start.

No pi process, no LLM, no compositor. ~3s.
"""

import json
import os
import shutil
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
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
    shutil.copytree(
        os.path.join(test_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    shutil.copy2(
        os.path.join(plugin_dir, "PiSession.qml"),
        os.path.join(shell_root, "PiSession.qml"),
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:sandbox-env", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    agent_dir = os.path.join(work_dir, "agent")
    state_dir = os.path.join(work_dir, "state")
    workspace = os.path.join(work_dir, "workspace")
    for d in (home, xdg_runtime, agent_dir, state_dir, workspace):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    # Sentinel PATH the test injects via the qs process env. The chat
    # shell must echo this value back through `--setenv=PATH=` so the
    # transient unit picks it up. Real values (/run/current-system/sw/bin
    # etc.) are irrelevant to the contract — we only care that the
    # shell forwards *its own* PATH verbatim.
    expected_path = "/test/sentinel/bin:/another/sentinel/sbin"

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "TEST_STATE_DIR": state_dir,
            "TEST_AGENT_DIR": agent_dir,
            "TEST_WORKSPACE": workspace,
            "PATH": expected_path,
        }
    )

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_stdout, stderr=qs_stderr
    )
    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:sandbox-env" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            qs_stdout.flush()
            qs_stderr.flush()
            with open(os.path.join(work_dir, "qs.stderr.log")) as fh:
                sys.stderr.write(fh.read())
            fail("IPC never registered")

        raw = qs_ipc_call(qs_bin, shell_qml, env, "buildCommand")
        argv = json.loads(raw)
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()

    want = f"--setenv=PATH={expected_path}"
    if want not in argv:
        setenvs = [a for a in argv if a.startswith("--setenv=PATH=")]
        fail(
            "PATH not forwarded into sandbox argv.\n"
            f"  expected: {want!r}\n"
            f"  observed PATH setenvs: {setenvs!r}\n"
            f"  full argv: {argv!r}"
        )

    print("OK")


if __name__ == "__main__":
    main()
