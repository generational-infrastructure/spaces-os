#!/usr/bin/env python3
"""Three-tier streaming e2e: real opencrow ↔ real pi ↔ mock LLM.

Pi spawns and streams a four-chunk SSE reply from the Python mock LLM.
Opencrow consumes pi's stdout, decodes the message_update events
through its own rpcEvent struct, and re-emits incremental deltas on
the chat socket. The driver connects as a socket client, sends a
prompt, and asserts each delta arrives as a kind:"delta" event before
the final kind:"msg".

Catches regressions like the json:"message" tag collision in opencrow's
pi_rpc.go that drops every message_update silently — the symptom is
a chat that no longer streams but still receives the final reply, which
neither streaming-e2e (stub pi) nor streaming-pi-e2e (no opencrow)
exercise on their own.
"""

import json
import os
import socket
import subprocess
import sys
import time

EXPECTED_PIECES = ["Hello", ", ", "world", "!"]
EXPECTED_REPLY = "".join(EXPECTED_PIECES)

# Mock LLM sleeps 100ms between chunks → ~300ms span over four deltas.
# Lower bound generous so slow sandboxes don't flake.
SPAN_MIN_S = 0.05
READ_TIMEOUT_S = 60


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def start_mock_llm(mock_script, work_dir):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    proc = subprocess.Popen(
        [sys.executable, mock_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
    )
    line = proc.stdout.readline()
    if not line:
        proc.kill()
        fail("mock-llm did not print URL on stdout")
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
        time.sleep(0.05)
    fail(f"chat socket {path} did not appear within {timeout}s")


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_events_until(sock_file, stop_when):
    events, times = [], []
    deadline = time.monotonic() + READ_TIMEOUT_S
    while time.monotonic() < deadline:
        line = sock_file.readline()
        if not line:
            fail("chat socket closed before stream completed")
        ev = json.loads(line)
        events.append(ev)
        times.append(time.monotonic())
        if stop_when(ev):
            return events, times
    fail(f"timed out after {READ_TIMEOUT_S}s waiting for final reply")


def assert_streaming(events, times):
    kinds = [ev.get("kind") for ev in events]
    deltas = [(ev, t) for ev, t in zip(events, times) if ev.get("kind") == "delta"]

    if not deltas:
        fail(
            "opencrow forwarded zero kind:'delta' events. The chat socket "
            "saw only the completed reply, meaning a decode/forward "
            "regression dropped every message_update from pi. Event kinds "
            f"observed: {kinds}"
        )

    pieces = [ev.get("text", "") for ev, _ in deltas]
    joined = "".join(pieces)
    if EXPECTED_REPLY not in joined:
        fail(
            f"reconstructed reply {joined!r} does not contain expected "
            f"{EXPECTED_REPLY!r}. Deltas were: {pieces}"
        )

    targets = {ev.get("target") for ev, _ in deltas}
    if len(targets) != 1 or None in targets or "" in targets:
        fail(f"deltas spread across multiple stream targets: {targets}")

    if len(deltas) >= 2:
        span = deltas[-1][1] - deltas[0][1]
        if span < SPAN_MIN_S:
            fail(
                f"deltas arrived within {span * 1000:.0f}ms (< "
                f"{SPAN_MIN_S * 1000:.0f}ms) — opencrow likely buffered the "
                "stream before forwarding"
            )

    last_delta_t = deltas[-1][1]
    final = next(
        (
            (ev, t)
            for ev, t in zip(events, times)
            if ev.get("kind") == "msg"
            and ev.get("msg", {}).get("dir") == "in"
            and ev.get("msg", {}).get("content", "") == EXPECTED_REPLY
        ),
        None,
    )
    if final is None:
        fail(
            "no final kind:'msg' with the assembled reply was observed; "
            f"observed kinds: {kinds}"
        )
    if final[1] < last_delta_t:
        fail("final msg event arrived before the last delta — ordering bug")


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
                # llama-swap-discover.ts registers the "local" provider
                # against the mock URL on session_start, matching how
                # opencrow-local is wired in production.
                "OPENCROW_PI_PROVIDER": "local",
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

        # Drain the initial status/models burst so the test only asserts
        # against events caused by our prompt.
        send(sock, {"cmd": "replay", "n": 10})
        time.sleep(0.5)

        send(sock, {"cmd": "send", "text": "stream please"})

        def is_final(ev):
            return (
                ev.get("kind") == "msg"
                and ev.get("msg", {}).get("dir") == "in"
                and ev.get("msg", {}).get("content", "") == EXPECTED_REPLY
            )

        events, times = read_events_until(sock_file, is_final)
        assert_streaming(events, times)

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
