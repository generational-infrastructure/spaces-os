#!/usr/bin/env python3
"""RPC new_session contract for pi --mode rpc.

Drives one prompt turn through pi, captures the active sessionId via
get_state, then issues { type: "new_session" } and asserts:

  - pi acks with success=True
  - the post-restart sessionId differs from the pre-restart one
  - messageCount goes back to 0
  - a subsequent prompt completes against the new session without
    surfacing the prior assistant text

The chat plugin's restart button is a thin QML wrapper over exactly
this RPC verb, so this is the cheapest layer at which a regression
would actually break the user-facing behavior.
"""

import json
import os
import subprocess
import sys
import threading
import time
from queue import Empty, Queue

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
        fail("mock LLM did not print its URL")
    return proc, line.decode().strip()


def read_loop(proc, q, log_file):
    for raw in proc.stdout:
        log_file.write(raw)
        log_file.flush()
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            q.put(json.loads(line))
        except Exception:
            continue
    q.put(None)


def send(proc, msg_id, payload):
    payload = {"id": msg_id, **payload}
    proc.stdin.write((json.dumps(payload) + "\n").encode())
    proc.stdin.flush()


def drain_until(q, predicate):
    """Pull events off q until `predicate(ev)` returns True; return that
    event. Times out via READ_TIMEOUT_S."""
    deadline = time.monotonic() + READ_TIMEOUT_S
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail(f"timed out waiting for {predicate.__name__}")
        try:
            ev = q.get(timeout=remaining)
        except Empty:
            fail(f"timed out (queue empty) waiting for {predicate.__name__}")
        if ev is None:
            fail(f"pi closed stdout before {predicate.__name__} matched")
        if predicate(ev):
            return ev


def main():
    if len(sys.argv) != 5:
        fail("usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> <work_dir>")
    pi_bin, mock_script, ext_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)
    agent_dir = os.path.join(work_dir, "agent")
    os.makedirs(agent_dir, exist_ok=True)
    session_dir = os.path.join(work_dir, "sessions")
    os.makedirs(session_dir, exist_ok=True)

    settings = {
        "extensions": [
            os.path.join(ext_dir, "llama-swap-discover.ts"),
        ],
        "defaultProvider": "local",
        "defaultModel": "mock-model",
        "quietStartup": True,
        "enableInstallTelemetry": False,
    }
    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(settings, fh)

    mock, url = start_mock_llm(mock_script, work_dir)
    try:
        env = os.environ.copy()
        env.update(
            {
                "PI_CODING_AGENT_DIR": agent_dir,
                "LLAMA_SWAP_BASE_URL": url,
                "PI_OFFLINE": "1",
                "PI_TELEMETRY": "0",
                "HOME": work_dir,
            }
        )
        cwd = os.path.join(work_dir, "pi-cwd")
        os.makedirs(cwd, exist_ok=True)
        pi_stdout_log = open(os.path.join(work_dir, "pi-stdout.log"), "wb")
        pi_stderr_log = open(os.path.join(work_dir, "pi-stderr.log"), "wb")
        proc = subprocess.Popen(
            [
                pi_bin,
                "--mode",
                "rpc",
                "--session-dir",
                session_dir,
                "--provider",
                "local",
                "--model",
                "mock-model",
                "--offline",
                "--no-context-files",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=pi_stderr_log,
            env=env,
            cwd=cwd,
        )

        q = Queue()
        reader = threading.Thread(
            target=read_loop, args=(proc, q, pi_stdout_log), daemon=True
        )
        reader.start()

        # Turn 1: drive a prompt through, wait for agent_end.
        send(proc, "p1", {"type": "prompt", "message": "hi"})
        agent_end_1 = drain_until(q, lambda ev: ev.get("type") == "agent_end")
        reply_1 = ""
        for m in agent_end_1.get("messages") or []:
            if (
                isinstance(m, dict)
                and m.get("role") == "assistant"
                and isinstance(m.get("content"), list)
            ):
                reply_1 = "".join(
                    c.get("text", "")
                    for c in m["content"]
                    if isinstance(c, dict) and c.get("type") == "text"
                ).strip()
        if not reply_1:
            fail("turn 1 produced no assistant text")

        # Snapshot state before restart.
        send(proc, "s1", {"type": "get_state"})
        state_1 = drain_until(
            q,
            lambda ev: (
                ev.get("type") == "response" and ev.get("command") == "get_state"
            ),
        )
        if not state_1.get("success"):
            fail(f"get_state(before) failed: {state_1}")
        session_id_before = (state_1.get("data") or {}).get("sessionId")
        message_count_before = (state_1.get("data") or {}).get("messageCount")
        if not session_id_before:
            fail(f"get_state(before) missing sessionId: {state_1}")
        if not message_count_before or message_count_before < 2:
            fail(f"get_state(before) expected ≥2 messages, got {message_count_before}")

        # The contract under test.
        send(proc, "n1", {"type": "new_session"})
        ns_resp = drain_until(
            q,
            lambda ev: (
                ev.get("type") == "response" and ev.get("command") == "new_session"
            ),
        )
        if not ns_resp.get("success"):
            fail(f"new_session failed: {ns_resp}")
        if (ns_resp.get("data") or {}).get("cancelled"):
            fail(f"new_session returned cancelled: {ns_resp}")

        # State after must be a fresh session with no messages.
        send(proc, "s2", {"type": "get_state"})
        state_2 = drain_until(
            q,
            lambda ev: (
                ev.get("type") == "response" and ev.get("command") == "get_state"
            ),
        )
        if not state_2.get("success"):
            fail(f"get_state(after) failed: {state_2}")
        session_id_after = (state_2.get("data") or {}).get("sessionId")
        message_count_after = (state_2.get("data") or {}).get("messageCount")
        if not session_id_after or session_id_after == session_id_before:
            fail(
                f"new_session did not change sessionId: "
                f"before={session_id_before} after={session_id_after}"
            )
        if message_count_after != 0:
            fail(f"new_session left messageCount={message_count_after}, expected 0")

        # Drive one more turn on the fresh session to prove it's usable
        # and isolated from turn 1's history. agent_end's messages list
        # should not surface reply_1.
        send(proc, "p2", {"type": "prompt", "message": "again"})
        agent_end_2 = drain_until(q, lambda ev: ev.get("type") == "agent_end")
        for m in agent_end_2.get("messages") or []:
            if not isinstance(m, dict):
                continue
            content = m.get("content")
            if not isinstance(content, list):
                continue
            text = "".join(
                c.get("text", "")
                for c in content
                if isinstance(c, dict) and c.get("type") == "text"
            )
            if reply_1 and reply_1 in text and m.get("role") == "assistant":
                # Only the post-restart assistant message is allowed —
                # which has the same mock text. Surface the count: in
                # the new session there should be exactly one assistant
                # message (this turn), not two.
                pass

        assistant_msgs = [
            m
            for m in (agent_end_2.get("messages") or [])
            if isinstance(m, dict) and m.get("role") == "assistant"
        ]
        if len(assistant_msgs) != 1:
            fail(
                "post-restart turn should have exactly one assistant "
                f"message, got {len(assistant_msgs)}: {assistant_msgs}"
            )

        print("OK")
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        mock.terminate()
        try:
            mock.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock.kill()


if __name__ == "__main__":
    main()
