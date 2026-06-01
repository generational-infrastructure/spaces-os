#!/usr/bin/env python3
"""Idle-reap exemption contract test.

Guards the PiChatBackend._reapIdle() change: the idle timer must NOT
kill a session that is actively generating (or a pending background
launch). A fire-and-forget agent that runs for half an hour can't be
reaped 10 minutes after the chat panel closes.

Two background launches share one backend:

  * A: prompt contains "HOLD" — the mock LLM streams the opening chunk
    then blocks before the closing chunk, so A stays mid-turn (busy)
    and pending.
  * B: a quick prompt that streams to completion, so B ends up running
    but idle (busy false, no longer pending).

Then _reapIdle() runs. PiSession.stop() shells out to `systemctl --user
stop pi-chat-<id>.service`; with no user manager here a stub systemctl
records the units the reaper *decided* to stop. We assert it stopped B's
unit and left A's alone, and that A is still streaming + busy.

Usage: driver.py <pi_bin> <qs_bin> <mock_llm> <ext_dir> <shared_dir>
                  <test_dir> <plugin_dir> <work_dir>

`shared_dir` is checks/pi-session-quick-launch (shell.qml + the
systemd-run / notify-send stubs are reused verbatim); `test_dir` is this
check's dir (the systemctl stub).
"""

from __future__ import annotations

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
        try:
            v = predicate()
            if v:
                return v
        except Exception:
            pass
        time.sleep(interval_s)
    return None


def start_mock_llm(mock_script: str, work_dir: str, hold_file: str):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    env = os.environ.copy()
    env["MOCK_HOLD_FILE"] = hold_file
    proc = subprocess.Popen(
        [sys.executable, mock_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
        env=env,
    )
    line = proc.stdout.readline()
    if not line:
        fail("mock LLM did not print its URL")
    return proc, line.decode().strip()


def stage_shell(shared_dir: str, plugin_dir: str, work_dir: str) -> str:
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
    shutil.copy2(os.path.join(shared_dir, "shell.qml"), shell_dst)
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def stage_bin(shared_dir: str, test_dir: str, pi_bin: str, work_dir: str) -> str:
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    shutil.copy2(
        os.path.join(shared_dir, "fake-systemd-run"),
        os.path.join(bin_dir, "systemd-run"),
    )
    shutil.copy2(
        os.path.join(shared_dir, "notify-send"), os.path.join(bin_dir, "notify-send")
    )
    shutil.copy2(
        os.path.join(test_dir, "systemctl"), os.path.join(bin_dir, "systemctl")
    )
    for n in ("systemd-run", "notify-send", "systemctl"):
        os.chmod(os.path.join(bin_dir, n), 0o755)
    pi_link = os.path.join(bin_dir, "pi")
    if os.path.exists(pi_link):
        os.remove(pi_link)
    os.symlink(pi_bin, pi_link)
    return bin_dir


def qs_ipc(
    qs_bin: str, shell_qml: str, env: dict, *args: str, check: bool = True
) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:quick-launch", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    if check and out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main() -> None:
    if len(sys.argv) != 9:
        fail(
            "usage: driver.py <pi_bin> <qs_bin> <mock_llm> <ext_dir> "
            "<shared_dir> <test_dir> <plugin_dir> <work_dir>"
        )
    (
        pi_bin,
        qs_bin,
        mock_script,
        ext_dir,
        shared_dir,
        test_dir,
        plugin_dir,
        work_dir,
    ) = sys.argv[1:9]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    agent_dir = os.path.join(work_dir, "agent")
    for d in (home, xdg_runtime, agent_dir):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(
            {
                "extensions": [os.path.join(ext_dir, "llama-swap-discover.ts")],
                "defaultProvider": "local",
                "defaultModel": "mock-model",
                "quietStartup": True,
                "enableInstallTelemetry": False,
            },
            fh,
        )

    shell_root = stage_shell(shared_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(shared_dir, test_dir, pi_bin, work_dir)

    hold_file = os.path.join(work_dir, "release")
    systemctl_witness = os.path.join(work_dir, "systemctl.log")
    open(systemctl_witness, "w").close()

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir, hold_file)

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "PI_CODING_AGENT_DIR": agent_dir,
            "LLAMA_SWAP_BASE_URL": mock_url,
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
            "NOTIFY_WITNESS": os.path.join(work_dir, "notify.log"),
            "SYSTEMCTL_WITNESS": systemctl_witness,
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def dump_logs():
        for name in ("qs.log", "mock-llm.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-6000:])
        if os.path.exists(systemctl_witness):
            sys.stderr.write("\n== systemctl witness ==\n")
            sys.stderr.write(open(systemctl_witness).read())

    def die(msg):
        dump_logs()
        # Best-effort release so the build doesn't hang on the held mock.
        open(hold_file, "w").close()
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
            return r.returncode == 0 and "test:quick-launch" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the IPC target")

        def session_ids():
            return {
                s["id"]
                for s in json.loads(qs_ipc(qs_bin, shell_qml, env, "listSessions"))
            }

        # ── A: the long-running, held background launch ──
        base = session_ids()
        qs_ipc(qs_bin, shell_qml, env, "launchBackground", "HOLD a long running task")
        a_id = wait_until(lambda: (session_ids() - base) or None, timeout_s=10)
        a_id = next(iter(a_id)) if a_id else None
        if not a_id:
            die("background launch A created no session")
        if not wait_until(
            lambda: qs_ipc(qs_bin, shell_qml, env, "sessionBusy", a_id) == "true",
            timeout_s=30,
        ):
            die("session A never became busy (held turn)")

        # ── B: a quick launch that runs to completion ──
        base2 = session_ids()
        qs_ipc(qs_bin, shell_qml, env, "launchBackground", "quick ping")
        b_id = wait_until(lambda: (session_ids() - base2) or None, timeout_s=10)
        b_id = next(iter(b_id)) if b_id else None
        if not b_id:
            die("background launch B created no session")
        # B finishes: busy clears and the reply streamed in.
        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "sessionBusy", b_id) == "false"
                and "Background task complete"
                in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", b_id)
            ),
            timeout_s=60,
        ):
            die("session B never completed its turn")
        # B's worker must still be up so the reaper has something to stop.
        if qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", b_id) != "true":
            die("session B worker exited before reap — nothing to reap")

        a_unit = f"pi-chat-{a_id}.service"
        b_unit = f"pi-chat-{b_id}.service"

        # ── the reaper runs ──
        qs_ipc(qs_bin, shell_qml, env, "reapIdle")

        # B (idle) must be stopped.
        if not wait_until(
            lambda: b_unit in open(systemctl_witness).read(), timeout_s=10
        ):
            die(f"reaper did not stop the idle session B ({b_unit})")

        # A (busy + pending) must SURVIVE: never handed to systemctl, and
        # still streaming + busy.
        time.sleep(0.5)
        witness = open(systemctl_witness).read()
        if a_unit in witness:
            die(f"reaper killed the busy background launch A ({a_unit})")
        if qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", a_id) != "true":
            die("session A worker is gone after reap — it should have survived")
        if qs_ipc(qs_bin, shell_qml, env, "sessionBusy", a_id) != "true":
            die("session A is no longer busy after reap — it was disturbed")

        # Release the held turn so A can finish and the build exits cleanly.
        open(hold_file, "w").close()
        print("PASS")
    finally:
        open(hold_file, "w").close()
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()


if __name__ == "__main__":
    main()
