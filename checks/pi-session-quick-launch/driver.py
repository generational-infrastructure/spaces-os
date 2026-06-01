#!/usr/bin/env python3
"""Quick-launch background-agent contract test.

Drives the real PiChatBackend through headless quickshell and asserts
the fire-and-forget launch path the Mod+/ quick bar uses:

  1. backend.launchBackground(prompt) creates a NEW session and spawns
     its `pi --mode rpc` worker WHILE THE PANEL IS HIDDEN (the normal
     lazy-spawn gate only spawns when the panel is open, so a working
     spawn here proves launchBackground bypasses the gate);
  2. the prompt streams a response back from the mock LLM;
  3. on completion the stub `notify-send` fires exactly once with title
     "Agent finished" and a body matching the prompt summary;
  4. the session is present in the index and selectable afterwards.

The plugin's PiSession spawns pi via `systemd-run --user --pipe …`.
There is no user systemd manager in the build sandbox, so a stub
`systemd-run` strips the sandbox flags and execs pi directly, inheriting
the quickshell environment (LLAMA_SWAP_BASE_URL → mock LLM, etc.).

Usage: driver.py <pi_bin> <qs_bin> <mock_llm> <ext_dir> <test_dir>
                  <plugin_dir> <work_dir>
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


def start_mock_llm(mock_script: str, work_dir: str):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    env = os.environ.copy()
    env["MOCK_REQUEST_LOG"] = os.path.join(work_dir, "mock-requests.log")
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


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Mirror the whole pi-chat tree, then drop in our test shell.qml.

    PiChatBackend pulls in PiSession, SignalConfirm, OpenUrlListener and
    the qs.Commons singletons, so we stage the entire plugin the way the
    panel-width check does."""
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


def stage_bin(test_dir: str, pi_bin: str, work_dir: str) -> str:
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    for name in ("fake-systemd-run", "notify-send"):
        dst = os.path.join(
            bin_dir, "systemd-run" if name == "fake-systemd-run" else name
        )
        shutil.copy2(os.path.join(test_dir, name), dst)
        os.chmod(dst, 0o755)
    # Real pi, reachable as bare `pi` (PiChatBackend's default piBin).
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


def read_notify(witness: str) -> list[list[str]]:
    if not os.path.exists(witness):
        return []
    out = []
    with open(witness) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def agent_finished_notifications(witness: str) -> list[list[str]]:
    return [a for a in read_notify(witness) if "Agent finished" in a]


def main() -> None:
    if len(sys.argv) != 8:
        fail(
            "usage: driver.py <pi_bin> <qs_bin> <mock_llm> <ext_dir> "
            "<test_dir> <plugin_dir> <work_dir>"
        )
    pi_bin, qs_bin, mock_script, ext_dir, test_dir, plugin_dir, work_dir = sys.argv[1:8]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    agent_dir = os.path.join(work_dir, "agent")
    for d in (home, xdg_runtime, agent_dir):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # pi agent config: local provider + mock model + the llama-swap
    # discovery extension (so pi resolves /v1/models against the mock).
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

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(test_dir, pi_bin, work_dir)
    notify_witness = os.path.join(work_dir, "notify.log")

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            # Inherited by the real pi through the systemd-run stub.
            "PI_CODING_AGENT_DIR": agent_dir,
            "LLAMA_SWAP_BASE_URL": mock_url,
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
            "NOTIFY_WITNESS": notify_witness,
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
        if os.path.exists(notify_witness):
            sys.stderr.write("\n== notify witness ==\n")
            sys.stderr.write(open(notify_witness).read())

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
            return r.returncode == 0 and "test:quick-launch" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:quick-launch IPC target")

        # Panel must be hidden — that's the whole point of a background launch.
        if qs_ipc(qs_bin, shell_qml, env, "panelVisible") != "false":
            die("panel reported visible; the test requires it hidden")

        sessions_before = json.loads(qs_ipc(qs_bin, shell_qml, env, "listSessions"))
        ids_before = {s["id"] for s in sessions_before}

        prompt = "Summarise today's standup notes"
        # The launch entry point: tolerate it being absent (RED) so we
        # still reach the observable assertions below.
        new_id = qs_ipc(qs_bin, shell_qml, env, "launchBackground", prompt, check=False)

        # (1) a new session must appear in the index.
        def new_session_id():
            sessions = json.loads(qs_ipc(qs_bin, shell_qml, env, "listSessions"))
            extra = [s for s in sessions if s["id"] not in ids_before]
            return extra[0]["id"] if extra else None

        sid = wait_until(new_session_id, timeout_s=10)
        if not sid:
            die("launchBackground did not create a new session in the index")
        if new_id and new_id != sid:
            sys.stderr.write(
                f"note: launchBackground returned {new_id!r}, index shows {sid!r}\n"
            )

        # (1b) the pi worker must spawn while the panel is hidden.
        if not wait_until(
            lambda: qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", sid) == "true",
            timeout_s=20,
        ):
            die("pi worker never spawned for the background session (panel hidden)")

        # (2) the prompt must stream a response from the mock LLM.
        if not wait_until(
            lambda: (
                "Background task complete"
                in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", sid)
            ),
            timeout_s=60,
        ):
            die("background session never received the streamed mock reply")

        # (3) exactly one "Agent finished" notification, body = summary.
        if not wait_until(
            lambda: len(agent_finished_notifications(notify_witness)) >= 1,
            timeout_s=30,
        ):
            die("no 'Agent finished' notification fired on completion")
        # Settle briefly to catch any duplicate.
        time.sleep(1.0)
        notifs = agent_finished_notifications(notify_witness)
        if len(notifs) != 1:
            die(
                f"expected exactly one 'Agent finished' notification, got {len(notifs)}: {notifs!r}"
            )
        argv = notifs[0]
        if "Agent finished" not in argv:
            die(f"notification title missing 'Agent finished': {argv!r}")
        # The prompt is <40 chars, so promptSummary returns it verbatim;
        # assert the exact body rather than a loose substring.
        body = argv[-1]
        if body != prompt:
            die(f"notification body {body!r} != expected prompt summary {prompt!r}")

        # (4) the session is selectable from the index.
        qs_ipc(qs_bin, shell_qml, env, "selectSession", sid)
        if qs_ipc(qs_bin, shell_qml, env, "activeSessionId") != sid:
            die("background session is not selectable from the index")

        print("PASS")
    finally:
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
