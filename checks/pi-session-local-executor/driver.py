#!/usr/bin/env python3
"""Headless check: pi-chat.json `localExecutor` -> executors entry -> WS hello.

Runs the real PiChatBackend in a headless quickshell, pointed via the
$SPACES_PI_CHAT_CONFIG seam at a fixture config, and asserts:

  (a) a config carrying localExecutor {id:"host", url:"ws://127.0.0.1:<p>"}
      materializes a backend.executors entry with token "" and tokenPath
      $XDG_RUNTIME_DIR/pi-sessiond/token;
  (b) the executor authenticates against a fake pi-sessiond whose expected
      token is the token FILE's content (hello -> welcome), proving the
      tokenPath plumbing end-to-end;
  (c) regression: without localExecutor the executors list stays empty —
      the transient no-executor state (spawns defer until configured).

This is the cheap per-feature counterpart to the full test-machine VM
test (which boots the shipping self-hosted topology): no compositor, no
pi, no LLM, no VM. ~10s.

Usage: driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir> <fake_daemon>
"""

import json
import os
import sys

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

TOKEN = "local-exec-secret"
SENTINEL_MODEL = "local-exec-sentinel"


def main():
    qs_bin, test_dir, plugin_dir, work_dir, fake_daemon = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)
    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    port = free_port()
    ws_url = f"ws://127.0.0.1:{port}"

    daemon = spawn(
        [sys.executable, fake_daemon, str(port), TOKEN],
        work_dir,
        "daemon.log",
    )

    qs = None

    def start_run(name: str, config: dict) -> Quickshell:
        """One headless quickshell instance with its own HOME + XDG_RUNTIME_DIR
        (per-run runtime dir keeps the IPC sockets of the two runs apart)."""
        run_dir = os.path.join(work_dir, name)
        os.makedirs(run_dir, exist_ok=True)
        config_path = os.path.join(run_dir, "pi-chat.json")
        with open(config_path, "w") as fh:
            json.dump(config, fh)
        env = qs_env(
            run_dir,
            extra={
                "QSG_RHI_BACKEND": "null",
                "SPACES_PI_CHAT_CONFIG": config_path,
            },
        )
        run = Quickshell(qs_bin, shell_qml, env, run_dir, ipc_target="test:localexec")
        run.start()
        return run

    def dump():
        path = os.path.join(work_dir, "daemon.log")
        if os.path.isfile(path):
            sys.stderr.write(f"\n== {path} ==\n" + open(path, errors="replace").read())
        if qs:
            qs.dump_logs()

    def die(msg):
        dump()
        fail(msg)

    try:
        # The executor connects once on startup, so the daemon must already
        # be listening (same race note as pi-session-ws).
        if not wait_for_port(port, timeout_s=15):
            dump()
            fail(f"fake daemon never listened on port {port} (exit={daemon.poll()})")

        # ── run 1: localExecutor configured ───────────────────────────────
        qs = start_run(
            "with-local",
            {
                "defaultModel": SENTINEL_MODEL,
                "localExecutor": {"id": "host", "url": ws_url},
            },
        )
        # Mint the per-login token where the daemon contract puts it:
        # $XDG_RUNTIME_DIR/pi-sessiond/token. Trailing newline checks
        # the panel trims the read. The daemon only answers `welcome` when
        # the hello token equals the file CONTENT, so a successful connect
        # proves the tokenPath plumbing end-to-end.
        token_dir = os.path.join(qs.env["XDG_RUNTIME_DIR"], "pi-sessiond")
        os.makedirs(token_dir, exist_ok=True)
        token_path = os.path.join(token_dir, "token")
        with open(token_path, "w") as fh:
            fh.write(TOKEN + "\n")
        os.chmod(token_path, 0o600)

        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the test:localexec IPC target")

        # (a) the executors entry materializes with the runtime token path.
        if not wait_until(
            lambda: bool(json.loads(qs.ipc("executorsJson"))), timeout_s=20
        ):
            die(f"executors never materialized (executors={qs.ipc('executorsJson')!r})")
        executors = json.loads(qs.ipc("executorsJson"))
        if len(executors) != 1:
            die(f"expected exactly one executor, got {executors!r}")
        entry = executors[0]
        expected = {
            "id": "host",
            "url": ws_url,
            "token": "",
            "tokenPath": token_path,
        }
        for k, v in expected.items():
            if entry.get(k) != v:
                die(f"executor entry {k}={entry.get(k)!r}, want {v!r} ({entry!r})")

        # (b) hello with the token-file content reaches welcome.
        if not wait_until(
            lambda: qs.ipc("executorConnected", "host") == "true", timeout_s=20
        ):
            die("loopback executor never connected/authenticated (token from file)")

        qs.stop()

        # ── run 2 (regression): no localExecutor -> executors stays empty ──
        qs = start_run(
            "without-local",
            {"defaultModel": SENTINEL_MODEL},
        )
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell (regression run) never bound the IPC target")
        # Gate on the sentinel so the empty-list assertion can't pass before
        # the FileView actually loaded the fixture config.
        if not wait_until(lambda: qs.ipc("cfgModel") == SENTINEL_MODEL, timeout_s=20):
            die(f"fixture config never loaded (defaultModel={qs.ipc('cfgModel')!r})")
        executors = json.loads(qs.ipc("executorsJson"))
        if executors != []:
            die(f"executors must stay empty without localExecutor, got {executors!r}")

        sys.stderr.write(
            "PASS: localExecutor entry + token-file hello/welcome + empty-without-config\n"
        )
    finally:
        if qs:
            qs.stop()
        reap(daemon)


if __name__ == "__main__":
    main()
