#!/usr/bin/env python3
"""Streaming integration test for pi --mode rpc against a mock LLM.

Sends a single prompt, then asserts:
  - message_update events with assistantMessageEvent.type=text_delta
    arrive incrementally (more than one, with non-zero spread)
  - the final agent_end carries the concatenated text
  - the assistant text matches the mock's pre-baked chunks

Usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> <work_dir>
"""

import json
import os
import subprocess
import sys
import threading
import time
from queue import Empty, Queue

EXPECTED_PIECES = ["Hello", ", ", "world", "!"]
EXPECTED_REPLY = "".join(EXPECTED_PIECES)

# Lower bound is generous so slow sandboxes don't flake; the mock
# server sleeps 100ms between chunks → ~300ms span.
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
        fail("mock LLM exited before printing its URL")
    return proc, line.decode().strip()


def read_loop(proc, q, log_file):
    for raw in proc.stdout:
        log_file.write(raw)
        log_file.flush()
        line = raw.decode().strip()
        if not line:
            continue
        try:
            q.put((time.monotonic(), json.loads(line)))
        except Exception:
            continue
    q.put(None)


def main():
    if len(sys.argv) != 5:
        fail("usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> <work_dir>")
    pi_bin, mock_script, ext_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)
    agent_dir = os.path.join(work_dir, "agent")
    os.makedirs(agent_dir, exist_ok=True)

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
                "--provider",
                "local",
                "--model",
                "mock-model",
                "--no-session",
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

        proc.stdin.write(
            (json.dumps({"type": "prompt", "message": "hi"}) + "\n").encode()
        )
        proc.stdin.flush()

        delta_times = []
        delta_texts = []
        deadline = time.monotonic() + READ_TIMEOUT_S
        final_text = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("timed out waiting for agent_end")
            try:
                item = q.get(timeout=remaining)
            except Empty:
                fail("timed out waiting for events")
            if item is None:
                fail("pi closed stdout before agent_end")
            t, ev = item
            if ev.get("type") == "message_update":
                me = ev.get("assistantMessageEvent") or {}
                if me.get("type") == "text_delta":
                    delta_times.append(t)
                    delta_texts.append(me.get("delta") or "")
            elif ev.get("type") == "agent_end":
                # Pull the final assistant text from agent_end's messages list.
                for m in ev.get("messages") or []:
                    if not isinstance(m, dict):
                        continue
                    if m.get("role") != "assistant":
                        continue
                    content = m.get("content")
                    if not isinstance(content, list):
                        continue
                    pieces = [
                        c.get("text", "")
                        for c in content
                        if isinstance(c, dict) and c.get("type") == "text"
                    ]
                    text = "".join(pieces).strip()
                    if text:
                        final_text = text
                break

        if len(delta_times) < 2:
            fail(f"expected ≥2 text_delta events, got {len(delta_times)}")
        span = delta_times[-1] - delta_times[0]
        if span < SPAN_MIN_S:
            fail(
                f"delta span {span:.3f}s < {SPAN_MIN_S}s; pi appears to be "
                "buffering chunks instead of streaming"
            )
        joined = "".join(delta_texts).strip()
        if EXPECTED_REPLY not in joined and joined != EXPECTED_REPLY:
            fail(f"streamed text {joined!r} did not match {EXPECTED_REPLY!r}")
        if (
            final_text
            and EXPECTED_REPLY not in final_text
            and final_text != EXPECTED_REPLY
        ):
            fail(f"agent_end text {final_text!r} did not match {EXPECTED_REPLY!r}")
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
