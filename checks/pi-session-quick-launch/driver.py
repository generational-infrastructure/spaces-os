#!/usr/bin/env python3
"""Quick-launch background-agent contract test.

Drives the real PiChatBackend through headless quickshell against a REAL
pi-sessiond (bun, embedding pi via its SDK) on loopback, and asserts the
fire-and-forget launch path the Mod+/ quick bar uses:

  1. backend.launchBackground(prompt) creates a NEW session pinned to the
     lone "host" executor and drives create_session over the WebSocket
     WHILE THE PANEL IS HIDDEN (the normal lazy-spawn gate only spawns
     when the panel is open, so a daemon-acked session here proves
     launchBackground bypasses the gate);
  2. the prompt streams a response back from the daemon's pi turn (which
     the mock LLM answers);
  3. on completion the stub `notify-send` (the panel still execs it from
     PATH) fires exactly once with title "Agent finished" and a body
     matching the prompt summary;
  4. exactly ONE index entry exists for the launch (the daemon's
     `sessions` broadcast must not re-import a duplicate), and the
     session is selectable afterwards.

Topology: the daemon authenticates panel connections against a token
FILE ($CREDENTIALS_DIRECTORY/token, the systemd LoadCredential seam) and
discovers its "local" provider models from the mock LLM's /v1/models.
The panel learns about the executor via $SPACES_PI_CHAT_EXECUTORS (its
test seam — /etc/spaces/pi-chat.json is unwritable in the sandbox). The
daemon's bash confinement wrapper is a passthrough stub; no bash tool
commands run in this check.

Usage: driver.py <daemon_bin> <qs_bin> <mock_llm> <systemd_run_stub>
                  <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time

TOKEN = "quick-launch-secret"


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


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for_port(port: int, *, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


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


def start_daemon(daemon_bin: str, stub: str, mock_url: str, port: int, work_dir: str):
    """Real pi-sessiond on a free loopback port, as executor id "host".

    The daemon discovers /v1/models from the mock LLM at startup (it only
    starts listening after discovery), copies the staged settings.json
    into its own pi agent dir, and reads its auth token from the
    credentials directory — the same seams the NixOS module wires up.
    """
    state_dir = os.path.join(work_dir, "daemon-state")
    creds_dir = os.path.join(work_dir, "creds")
    os.makedirs(state_dir, exist_ok=True)
    os.makedirs(creds_dir, exist_ok=True)
    with open(os.path.join(creds_dir, "token"), "w") as fh:
        fh.write(TOKEN + "\n")

    # pi settings template (SPACES_SESSIOND_PI_SETTINGS): the daemon copies
    # it to $STATE_DIRECTORY/pi-agent/settings.json for its embedded pi.
    # Defaults match the mock; the daemon does its own llama-swap model
    # discovery, so no discovery extension is listed here.
    settings_path = os.path.join(work_dir, "settings.json")
    with open(settings_path, "w") as fh:
        json.dump(
            {
                "defaultProvider": "local",
                "defaultModel": "mock-model",
                "quietStartup": True,
                "enableInstallTelemetry": False,
            },
            fh,
        )

    env = os.environ.copy()
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(port),
            "SPACES_SESSIOND_EXECUTOR_ID": "host",
            "CREDENTIALS_DIRECTORY": creds_dir,
            "LLAMA_SWAP_BASE_URL": mock_url,
            "SPACES_SESSIOND_DEFAULT_MODEL": "mock-model",
            "SPACES_SESSIOND_PI_SETTINGS": settings_path,
            "SPACES_SESSIOND_SYSTEMD_RUN": stub,
            "STATE_DIRECTORY": state_dir,
            # Idle-GC off: the background session must survive untouched
            # until every assertion has read it.
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
        }
    )
    log = open(os.path.join(work_dir, "daemon.log"), "wb")
    return subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Mirror the whole pi-chat tree, then drop in our test shell.qml.

    PiChatBackend pulls in PiExecutor, PiSession and the qs.Commons
    singletons, so we stage the entire plugin the way the sibling
    executor checks do."""
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


def stage_bin(test_dir: str, work_dir: str) -> str:
    """PATH overlay for quickshell: just the notify-send witness stub.

    The panel no longer spawns any local worker — sessions live on the
    executor daemon — but it still execs `notify-send` for the completion
    toast."""
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    dst = os.path.join(bin_dir, "notify-send")
    shutil.copy2(os.path.join(test_dir, "notify-send"), dst)
    os.chmod(dst, 0o755)
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
            "usage: driver.py <daemon_bin> <qs_bin> <mock_llm> "
            "<systemd_run_stub> <test_dir> <plugin_dir> <work_dir>"
        )
    daemon_bin, qs_bin, mock_script, stub, test_dir, plugin_dir, work_dir = sys.argv[
        1:8
    ]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(test_dir, work_dir)
    notify_witness = os.path.join(work_dir, "notify.log")

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)

    port = free_port()
    daemon_proc = start_daemon(daemon_bin, stub, mock_url, port, work_dir)
    if not wait_for_port(port, timeout_s=60):
        fail(f"pi-sessiond never listened on port {port} (exit={daemon_proc.poll()})")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "NOTIFY_WITNESS": notify_witness,
            # Executor topology seam: one remote executor "host" — the real
            # daemon above. With a single executor and no defaultExecutor,
            # defaultExecutorId resolves to it, which is where the quick-bar
            # session must land.
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [{"id": "host", "url": f"ws://127.0.0.1:{port}", "token": TOKEN}]
            ),
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def dump_logs():
        for name in ("qs.log", "mock-llm.log", "daemon.log"):
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

    def raw_sessions():
        return json.loads(qs_ipc(qs_bin, shell_qml, env, "rawSessions"))

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

        # The launch needs a welcomed executor (create_session is queued
        # behind whenConnected, but a connected panel makes failures sharp).
        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "executorConnected", "host") == "true"
            ),
            timeout_s=30,
        ):
            die("panel never connected/authenticated to the host executor")

        # Panel must be hidden — that's the whole point of a background launch.
        if qs_ipc(qs_bin, shell_qml, env, "panelVisible") != "false":
            die("panel reported visible; the test requires it hidden")

        ids_before = {s["id"] for s in raw_sessions()}

        prompt = "Summarise today's standup notes"
        # The launch entry point: tolerate it being absent (RED) so we
        # still reach the observable assertions below.
        new_id = qs_ipc(qs_bin, shell_qml, env, "launchBackground", prompt, check=False)

        # (1) a new session must appear in the index, pinned to "host".
        def new_sessions():
            extra = [s for s in raw_sessions() if s["id"] not in ids_before]
            return extra or None

        extra = wait_until(new_sessions, timeout_s=10)
        if not extra:
            die("launchBackground did not create a new session in the index")
        sid = extra[0]["id"]
        if new_id and new_id != sid:
            sys.stderr.write(
                f"note: launchBackground returned {new_id!r}, index shows {sid!r}\n"
            )
        if extra[0]["executor"] != "host":
            die(
                "background session must land on the lone executor "
                f'"host", got {extra[0]["executor"]!r}: {extra[0]!r}'
            )

        # (1b) the session must run while the panel is hidden: spawn flips
        # the running flag, and the daemon acking create_session stamps a
        # daemonSessionId on the entry — proof the launch reached the
        # executor rather than waiting for a panel-open lazy spawn.
        if not wait_until(
            lambda: qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", sid) == "true",
            timeout_s=20,
        ):
            die("background session never started running (panel hidden)")
        if not wait_until(
            lambda: [
                s for s in raw_sessions() if s["id"] == sid and s["daemonSessionId"]
            ],
            timeout_s=20,
        ):
            die("daemon never acked create_session (no daemonSessionId stamped)")

        # (2) the prompt must stream a response back over the WS — the
        # daemon's pi turn, answered by the mock LLM.
        if not wait_until(
            lambda: (
                "Background task complete"
                in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", sid)
            ),
            timeout_s=60,
        ):
            die("background session never received the streamed reply")

        # (1c) still exactly ONE entry for the launch: the daemon's
        # `sessions` broadcast (fired on create_session) must not have
        # re-imported the same daemon session as a duplicate. Settle so a
        # deferred import can't sneak in after the count.
        time.sleep(1.5)
        entries = [s for s in raw_sessions() if s["id"] not in ids_before]
        if len(entries) != 1:
            die(
                f"expected exactly ONE new index entry, got {len(entries)}: {entries!r}"
            )

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
        daemon_proc.terminate()
        try:
            daemon_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_proc.kill()
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()


if __name__ == "__main__":
    main()
