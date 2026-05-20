#!/usr/bin/env python3
"""Regression for the chat panel's reset button losing the user's
model choice.

Background: clicking "reset" in the chat panel sends `!restart`,
which kills the current pi process and respawns fresh. Before
opencrow @ 3e96f2c the worker only switched the running pi via RPC
on set-model — it never updated PiConfig — so the next ensurePi
spawn rebuilt args from OPENCROW_PI_MODEL and dropped the user's
selection.

This test drives the real socket protocol end-to-end:

  1. Connect, drain initial events.
  2. set-model from the default (mock-model) to alt-model.
  3. Send !restart, wait for the "Session restarted" ack.
  4. list-models, assert the active entry is still alt-model.

Step 4 cold-spawns pi as a side-effect, so the active flag reflects
what arguments the *fresh* process was started with — exactly the
regressed path.
"""

import json
import os
import socket
import subprocess
import sys
import time

READ_TIMEOUT_S = 60


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def start_mock_llm(mock_script, work_dir):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    proc = subprocess.Popen(
        ["python3", mock_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
    )
    line = proc.stdout.readline()
    if not line:
        fail("mock LLM exited before printing its URL")
    return proc, line.decode().strip()


def write_pi_settings(agent_dir, extension_paths):
    os.makedirs(agent_dir, exist_ok=True)
    settings_path = os.path.join(agent_dir, "settings.json")
    with open(settings_path, "w") as fh:
        json.dump({"extensions": list(extension_paths)}, fh)
    secrets_path = os.path.join(agent_dir, "secrets.json")
    with open(secrets_path, "w") as fh:
        json.dump({}, fh)


def wait_for_socket(path, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.1)
    fail(f"chat socket {path} did not appear within {timeout}s")


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_event(sock_file, predicate, what):
    """Read newline-delimited JSON until predicate(ev) is true."""
    deadline = time.monotonic() + READ_TIMEOUT_S
    while time.monotonic() < deadline:
        line = sock_file.readline()
        if not line:
            fail(f"socket closed before observing {what}")
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if predicate(ev):
            return ev
    fail(f"timed out after {READ_TIMEOUT_S}s waiting for {what}")


def active_model(models_ev):
    for m in models_ev.get("models", []) or []:
        if m.get("active"):
            return f"{m.get('provider')}/{m.get('id')}"
    return None


def main():
    if len(sys.argv) != 6:
        fail(
            "usage: driver.py <opencrow-bin> <pi-bin> <mock-llm-script> "
            "<extension-path> <work-dir>"
        )

    opencrow_bin, pi_bin, mock_script, extension_path, work_dir = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)
    agent_dir = os.path.join(work_dir, "agent")
    session_dir = os.path.join(work_dir, "sessions")
    sock_path = os.path.join(session_dir, "chat.sock")
    os.makedirs(session_dir, exist_ok=True)

    write_pi_settings(agent_dir, [extension_path])

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)
    opencrow_log = open(os.path.join(work_dir, "opencrow.log"), "w")
    opencrow_proc = None
    try:
        env = dict(os.environ)
        env.update(
            {
                "OPENCROW_BACKEND": "socket",
                "OPENCROW_SOCKET_PATH": sock_path,
                "OPENCROW_SOCKET_NAME": "TestBot",
                "OPENCROW_PI_BINARY": pi_bin,
                "OPENCROW_PI_SESSION_DIR": session_dir,
                "OPENCROW_PI_WORKING_DIR": work_dir,
                "OPENCROW_PI_PROVIDER": "local",
                # Default model = mock-model so a regression (cfg not
                # updated on set-model) snaps back here after !restart.
                "OPENCROW_PI_MODEL": "mock-model",
                "OPENCROW_PI_IDLE_TIMEOUT": "10m",
                "LLAMA_SWAP_BASE_URL": mock_url,
                "PI_CODING_AGENT_DIR": agent_dir,
                "HOME": work_dir,
            }
        )

        opencrow_proc = subprocess.Popen(
            [opencrow_bin],
            env=env,
            stdout=opencrow_log,
            stderr=subprocess.STDOUT,
            cwd=work_dir,
        )

        wait_for_socket(sock_path)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(sock_path)
        sock_file = sock.makefile("r", buffering=1, encoding="utf-8")
        sock.settimeout(READ_TIMEOUT_S)

        # Drain whatever the daemon emits on connect (status, possibly a
        # prefetched models list) before issuing commands of our own.
        send(sock, {"cmd": "replay", "n": 10})
        time.sleep(0.5)

        # Switch to alt-model. handleSetModel broadcasts a full models
        # list once the worker confirms the swap; wait for that as the
        # success signal.
        send(
            sock,
            {"cmd": "set-model", "provider": "local", "modelId": "alt-model"},
        )
        ev = read_event(
            sock_file,
            lambda e: (
                e.get("kind") == "models" and active_model(e) == "local/alt-model"
            ),
            "models event marking alt-model active",
        )
        if active_model(ev) != "local/alt-model":
            fail(f"set-model did not switch active model: {ev}")

        # !restart goes through the regular send path. The daemon echoes
        # "Session restarted." once handleRestart fires; wait for that
        # bubble so we know the next pi spawn will be fresh.
        send(sock, {"cmd": "send", "text": "!restart"})
        read_event(
            sock_file,
            lambda e: (
                e.get("kind") == "msg"
                and e.get("msg", {}).get("dir") == "in"
                and "Session restarted" in (e.get("msg", {}).get("content", ""))
            ),
            "Session restarted ack",
        )

        # Cold-spawns pi with whatever args the worker now derives from
        # PiConfig. The active flag in this list comes straight from
        # pi's get_state, so it tells us what model the *fresh* pi was
        # started with — the regressed path.
        send(sock, {"cmd": "list-models"})
        ev = read_event(
            sock_file,
            lambda e: e.get("kind") == "models" and active_model(e) is not None,
            "models event after restart",
        )

        got = active_model(ev)
        if got != "local/alt-model":
            fail(
                f"active model after !restart = {got!r}, want "
                "'local/alt-model'; the worker reverted to "
                "OPENCROW_PI_MODEL on restart instead of preserving "
                "the user's set-model choice"
            )

    finally:
        if opencrow_proc is not None:
            opencrow_proc.terminate()
            try:
                opencrow_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                opencrow_proc.kill()
                opencrow_proc.wait()
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()
        opencrow_log.close()
        log_path = os.path.join(work_dir, "opencrow.log")
        if os.path.exists(log_path):
            sys.stderr.write("--- opencrow log ---\n")
            with open(log_path) as fh:
                sys.stderr.write(fh.read())
            sys.stderr.write("--- end opencrow log ---\n")

    print("OK")


if __name__ == "__main__":
    main()
