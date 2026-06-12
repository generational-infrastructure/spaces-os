#!/usr/bin/env python3
"""Model-picker contract test.

The empty-dropdown class of bug: the daemon discovers models, the
session's get_available_models round-trip fills chat.models, and the
panel's combobox STILL shows nothing — because the widget's current
item never re-resolves when the list and activeModel arrive after it
was created. Data-layer probes (sessionModel-style) can't see that, so
this driver asserts on the real NComboBox staged next to the backend
(see shell.qml), through two scenarios:

  1. first-open: fresh state, openPanel() (the Panel.onCompleted
     listModels call) races the async WS round-trip — the combobox must
     converge to a non-empty display naming the active model.
  2. reopen-with-persisted-entry: quickshell restarts on a sessions.json
     whose entry carries the daemon session id AND the legacy
     executor:"" pin (the shape real deployments persisted before the
     default-executor fallback) — attach path instead of create, same
     display contract.

Harness mirrors pi-session-quick-launch: REAL pi-sessiond (bun) backed
by the shared mock LLM serving a multi-model list.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time

TOKEN = "model-picker-secret"
# Two models so "a" list is distinguishable from "the" list; the daemon
# default (settings.json) is mock-model, so the active entry is known.
MODELS = ["mock-model", "mock-alt"]
EXPECTED_DISPLAY = "[host] mock-model"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
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
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.3)
    return False


def start_mock_llm(mock_script: str, work_dir: str):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    env = os.environ.copy()
    env["MOCK_REQUEST_LOG"] = os.path.join(work_dir, "mock-requests.log")
    env["MOCK_MODELS_JSON"] = json.dumps(MODELS)
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
    """Real pi-sessiond as executor "host"; discovers MODELS from the mock."""
    state_dir = os.path.join(work_dir, "daemon-state")
    creds_dir = os.path.join(work_dir, "creds")
    os.makedirs(state_dir, exist_ok=True)
    os.makedirs(creds_dir, exist_ok=True)
    with open(os.path.join(creds_dir, "token"), "w") as fh:
        fh.write(TOKEN + "\n")

    settings_path = os.path.join(work_dir, "settings.json")
    with open(settings_path, "w") as fh:
        json.dump(
            {
                "defaultProvider": "local",
                "defaultModel": MODELS[0],
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
            "SPACES_SESSIOND_DEFAULT_MODEL": MODELS[0],
            "SPACES_SESSIOND_PI_SETTINGS": settings_path,
            "SPACES_SESSIOND_SYSTEMD_RUN": stub,
            "STATE_DIRECTORY": state_dir,
            # The persisted-entry scenario re-attaches after a quickshell
            # restart; the daemon session must survive the gap.
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
        }
    )
    log = open(os.path.join(work_dir, "daemon.log"), "wb")
    return subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Mirror the pi-chat tree, drop in the test shell.qml (sibling pattern)."""
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


class Shell:
    """One quickshell lifetime against the staged shell.qml."""

    def __init__(self, qs_bin: str, shell_qml: str, env: dict, log_path: str):
        self.qs_bin = qs_bin
        self.shell_qml = shell_qml
        self.env = env
        self.log = open(log_path, "w")
        self.proc = subprocess.Popen(
            [qs_bin, "-p", shell_qml], env=env, stdout=self.log, stderr=self.log
        )

    def ipc(self, *args: str, check: bool = True) -> str:
        cmd = [
            self.qs_bin,
            "ipc",
            "-p",
            self.shell_qml,
            "call",
            "test:model-picker",
            *args,
        ]
        out = subprocess.run(cmd, env=self.env, capture_output=True, text=True)
        if check and out.returncode != 0:
            fail(f"ipc {args} failed: {out.stdout!r} {out.stderr!r}")
        return out.stdout.strip()

    def wait_ready(self):
        if not wait_until(
            lambda: self.ipc("ping", check=False) == "true", timeout_s=60
        ):
            fail("shell IPC never came up")

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def assert_picker(shell: Shell, scenario: str, work_dir: str) -> None:
    """The two-layer contract: session data, then what the widget shows."""

    def dump_and_fail(msg: str) -> None:
        for name in ("daemon.log", "qs-1.log", "qs-2.log", "mock-llm.log"):
            path = os.path.join(work_dir, name)
            if os.path.exists(path):
                with open(path, errors="replace") as fh:
                    tail = fh.readlines()[-40:]
                sys.stderr.write(f"== {name} ==\n" + "".join(tail))
        fail(msg)

    # Data layer: the WS round-trip fills the session's model list and pi
    # reports the active model. openPanel (Panel.onCompleted's listModels)
    # is re-issued inside the poll: at process start backend.chat may
    # still be the null placeholder while the sessions index loads, and a
    # listModels against it is a silent no-op — the real Panel only ever
    # runs onCompleted after the backend is live, so retrying is the
    # faithful (and idempotent) equivalent.
    def data_ready():
        shell.ipc("openPanel")
        return shell.ipc("modelsCount") == str(len(MODELS))

    if not wait_until(data_ready, timeout_s=60):
        dump_and_fail(f"[{scenario}] session.models never reached {len(MODELS)}")
    if not wait_until(lambda: shell.ipc("activeModel") != "", timeout_s=30):
        dump_and_fail(f"[{scenario}] activeModel never set")

    # Presentation layer: the combobox must converge on its own — no
    # user interaction. This is the leg the empty-dropdown bug breaks:
    # items exist (count is right) but the closed display stays blank.
    if not wait_until(
        lambda: shell.ipc("comboCount") == str(len(MODELS)), timeout_s=30
    ):
        dump_and_fail(f"[{scenario}] combobox item count never reached {len(MODELS)}")
    if not wait_until(
        lambda: shell.ipc("comboDisplayText") == EXPECTED_DISPLAY, timeout_s=15
    ):
        dump_and_fail(
            f"[{scenario}] combobox display never showed the active model: "
            f"displayText={shell.ipc('comboDisplayText')!r} "
            f"currentIndex={shell.ipc('comboCurrentIndex')} "
            f"activeModel={shell.ipc('activeModel')!r}"
        )


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

    # Deployment parity: the NixOS module's tmpfiles rules pre-create an
    # EMPTY sessions.json (the index FileView only bootstraps "Chat 1"
    # from onLoaded — a missing file never fires it). Same here, or the
    # backend has no session at all and every probe is vacuous.
    state_dir = os.path.join(home, ".local", "state", "spaces", "pi")
    os.makedirs(state_dir, exist_ok=True)
    with open(os.path.join(state_dir, "sessions.json"), "w") as fh:
        fh.write("")

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)
    port = free_port()
    daemon_proc = start_daemon(daemon_bin, stub, mock_url, port, work_dir)
    if not wait_for_port(port, timeout_s=60):
        fail(f"pi-sessiond never listened on {port} (exit={daemon_proc.poll()})")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [{"id": "host", "url": f"ws://127.0.0.1:{port}", "token": TOKEN}]
            ),
        }
    )

    try:
        # ── 1. first-open: fresh state, create_session path ──
        shell = Shell(qs_bin, shell_qml, env, os.path.join(work_dir, "qs-1.log"))
        try:
            shell.wait_ready()
            assert_picker(shell, "first-open", work_dir)
            raw = json.loads(shell.ipc("rawSessions"))
            if not raw or not raw[0]["daemonSessionId"]:
                fail(f"no daemon session persisted after first open: {raw}")
        finally:
            shell.stop()
        print("OK: first-open picker populated")

        # ── 2. persisted entry, attach path, legacy executor:"" pin ──
        # Real deployments persisted entries with executor:"" (minted
        # before the executor inventory loaded); resolution must fall
        # back to the default executor and re-attach to the SAME daemon
        # session, and the picker must populate again.
        index_path = os.path.join(
            home, ".local", "state", "spaces", "pi", "sessions.json"
        )
        with open(index_path) as fh:
            pre = fh.read()
        index = json.loads(pre)
        for entry in index["sessions"]:
            entry["executor"] = ""
        with open(index_path, "w") as fh:
            json.dump(index, fh)

        shell = Shell(qs_bin, shell_qml, env, os.path.join(work_dir, "qs-2.log"))
        try:
            shell.wait_ready()
            assert_picker(shell, "reopen-persisted", work_dir)
            raw2 = json.loads(shell.ipc("rawSessions"))
            if all(s["daemonSessionId"] != raw[0]["daemonSessionId"] for s in raw2):
                with open(os.path.join(work_dir, "qs-2.log"), errors="replace") as fh:
                    sys.stderr.write("== qs-2.log (full) ==\n" + fh.read())
                fail(
                    "reopen did not re-attach to the persisted daemon session: "
                    f"{raw2} vs {raw[0]}"
                )
        finally:
            shell.stop()
        print("OK: reopen-persisted picker populated")
    finally:
        daemon_proc.terminate()
        mock_proc.kill()


if __name__ == "__main__":
    main()
