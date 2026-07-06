#!/usr/bin/env python3
"""Stale daemon-session recovery contract.

A persisted panel entry carries a daemonSessionId the daemon does not
know: the daemon's state was wiped, the session was deleted by another
client, or (pre-fix) a turnless session never committed a jsonl. The
attach bounces with a correlated "no such session" — the session MUST
recover by dropping the stale mapping and minting a fresh daemon
session (models populate, prompts become possible), instead of wedging
attached-but-dead with every command bouncing forever. This was the
production "panel shows no models" wedge after a daemon restart.

Also pins the executor stamp: the staged entry carries the legacy
executor:"" pin; once the executor inventory loads, the persisted entry
must be re-stamped with the default executor id so a later
defaultExecutor config change cannot silently migrate the chat away
from the daemon that owns its history.

Harness mirrors pi-session-model-picker: REAL pi-sessiond (bun) backed
by the shared mock LLM. No VM, no compositor. ~10-30s.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid

from qs_harness import (
    Quickshell,
    fail,
    free_port,
    qs_env,
    reap,
    spawn,
    stage_shell,
    wait_for_port,
    wait_until,
)

TOKEN = "stale-recovery-secret"
MODELS = ["mock-model", "mock-alt"]
GHOST_DAEMON_ID = str(uuid.uuid4())


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
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
        }
    )
    return spawn([daemon_bin], work_dir, "daemon.log", env=env)


def stage_stale_index(home: str) -> str:
    """A sessions.json whose only entry points at a daemon session that
    does not exist, with the legacy executor:"" pin."""
    state_dir = os.path.join(home, ".local", "state", "spaces", "pi")
    os.makedirs(state_dir, exist_ok=True)
    now_ms = int(time.time() * 1000)
    index = {
        "version": 1,
        "activeSessionId": "stalechat0001",
        "lastImportTime": now_ms,
        "sessions": [
            {
                "id": "stalechat0001",
                "name": "Chat 1",
                "workspacePath": os.path.join(home, "workspace"),
                "executor": "",
                "daemonSessionId": GHOST_DAEMON_ID,
                "model": "",
                "trusted": False,
                "unread": 0,
                "memoryEnabled": True,
                "createdAt": now_ms,
                "lastActiveAt": now_ms,
            }
        ],
    }
    path = os.path.join(state_dir, "sessions.json")
    with open(path, "w") as fh:
        json.dump(index, fh)
    return path


class Shell:
    def __init__(self, qs_bin: str, shell_qml: str, env: dict, work_dir: str):
        self.qs = Quickshell(
            qs_bin, shell_qml, env, work_dir, ipc_target="test:stale-recovery"
        )
        self.qs.start()

    def ipc(self, *args: str, check: bool = True) -> str:
        try:
            return self.qs.ipc(*args)
        except RuntimeError as exc:
            if check:
                fail(f"ipc {args} failed: {exc}")
            return ""

    def wait_ready(self):
        if not wait_until(
            lambda: self.ipc("ping", check=False) == "true", timeout_s=60
        ):
            fail("shell IPC never came up")

    def stop(self):
        reap(self.qs.proc, timeout_s=10)


def main() -> None:
    if len(sys.argv) != 8:
        fail(
            "usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir> "
            "<daemon_bin> <mock_llm> <systemd_run_stub>"
        )
    qs_bin, test_dir, plugin_dir, work_dir, daemon_bin, mock_script, stub = sys.argv[
        1:8
    ]
    os.makedirs(work_dir, exist_ok=True)

    home = work_dir  # qs_env pins HOME to work_dir; the session index lives beneath it

    index_path = stage_stale_index(home)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)
    port = free_port()
    daemon_proc = start_daemon(daemon_bin, stub, mock_url, port, work_dir)
    if not wait_for_port(port, timeout_s=60):
        fail(f"pi-sessiond never listened on {port} (exit={daemon_proc.poll()})")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            # Neutralize any real machine config (/etc/spaces/pi-chat.json
            # exists on dev machines and would shadow the executor seam).
            "SPACES_PI_CHAT_CONFIG": os.path.join(work_dir, "no-config.json"),
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [{"id": "host", "url": f"ws://127.0.0.1:{port}", "token": TOKEN}]
            ),
        },
    )

    def dump_and_fail(msg: str) -> None:
        for name in ("daemon.log", "qs.stdout.log", "qs.stderr.log", "mock-llm.log"):
            path = os.path.join(work_dir, name)
            if os.path.exists(path):
                with open(path, errors="replace") as fh:
                    tail = fh.readlines()[-40:]
                sys.stderr.write(f"== {name} ==\n" + "".join(tail))
        fail(msg)

    try:
        shell = Shell(qs_bin, shell_qml, env, work_dir)
        try:
            shell.wait_ready()

            # The attach against GHOST_DAEMON_ID bounces; recovery must
            # mint a fresh daemon session and the models round-trip must
            # complete against it. openPanel retried inside the poll —
            # backend.chat is the null placeholder until the index loads.
            def recovered():
                shell.ipc("openPanel")
                count = shell.ipc("modelsCount")
                # ">=": a dev machine running this driver outside the nix
                # sandbox may surface extra providers; the sandbox serves
                # exactly MODELS.
                return count.isdigit() and int(count) >= len(MODELS)

            if not wait_until(recovered, timeout_s=60):
                dump_and_fail(
                    f"session never recovered from the stale daemon id: "
                    f"models={shell.ipc('modelsCount')} "
                    f"raw={shell.ipc('rawSessions')} "
                    f"debug={shell.ipc('debugState', check=False)}"
                )

            raw = json.loads(shell.ipc("rawSessions"))
            entry = raw[0]
            if entry["daemonSessionId"] in ("", GHOST_DAEMON_ID):
                dump_and_fail(f"stale daemon id was not replaced: {entry}")
            # Executor stamp: the legacy "" pin must be re-stamped with
            # the default executor once the inventory loaded.
            if entry["executor"] != "host":
                dump_and_fail(f"legacy executor pin was not stamped: {entry}")

            # The restamped mapping must be durable: the on-disk index
            # carries the fresh daemon id, so the next panel start
            # attaches instead of chasing the ghost again.
            def persisted():
                with open(index_path) as fh:
                    data = json.load(fh)
                s = data["sessions"][0]
                return (
                    s.get("daemonSessionId") == entry["daemonSessionId"]
                    and s.get("executor") == "host"
                )

            if not wait_until(persisted, timeout_s=30):
                with open(index_path) as fh:
                    dump_and_fail(f"recovery was not persisted: {fh.read()}")
        finally:
            shell.stop()
        print("OK: stale daemon session recovered, restamped, persisted")
    finally:
        daemon_proc.terminate()
        mock_proc.kill()


if __name__ == "__main__":
    main()
