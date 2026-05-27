#!/usr/bin/env python3
"""Integration test for the `notifications` skill.

Spawns pi --mode rpc with the bash-confirm extension loaded, the
`notifications` CLI on PATH, and a seeded notifications history file
under DISTRO_NOTIFICATIONS_FILE. The mock LLM issues a single
`notifications list --json --limit 2` bash call and then echoes the
tool output back as the assistant reply.

Assertions:
  * No `extension_ui_request` arrives — the bash-confirm allowlist
    whitelists `notifications`, so the call must run unprompted.
  * Assistant text contains the seeded notification's summary, proving
    pi actually executed the CLI against our fixture (vs. e.g. a stub
    that returns "(no notifications)").

Usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> <notifications_bin> <work_dir>
"""

import json
import os
import subprocess
import sys
import threading
import time
from queue import Empty, Queue

SEEDED_SUMMARY = "test-seeded-notification"


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


class PiClient:
    """Wraps a pi --mode rpc subprocess with line-buffered stdin/stdout."""

    def __init__(self, pi_bin, env, work_dir):
        self.proc = subprocess.Popen(
            [
                pi_bin,
                "--mode",
                "rpc",
                "--provider",
                "local",
                "--model",
                "mock-notifications-model",
                "--no-session",
                "--offline",
                "--no-context-files",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=work_dir,
        )
        self.events = Queue()
        self._stderr_log = open(os.path.join(work_dir, "pi-stderr.log"), "ab")
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        self._err_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self._err_reader.start()

    def _read_stdout(self):
        for raw in self.proc.stdout:
            try:
                ev = json.loads(raw.decode().strip())
            except Exception:
                continue
            self.events.put(ev)
        self.events.put(None)

    def _read_stderr(self):
        for raw in self.proc.stderr:
            self._stderr_log.write(raw)
            self._stderr_log.flush()

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def drain_until(self, predicate, timeout=60):
        collected = []
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("timed out draining events")
            try:
                ev = self.events.get(timeout=remaining)
            except Empty:
                fail("timed out draining events")
            if ev is None:
                fail("pi closed stdout early")
            collected.append(ev)
            if predicate(ev):
                return collected

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def seed_notifications(path):
    """Write a fixture history file in the schema the notifications skill reads.

    The shape matches noctalia's persistent history file by design — the
    skill was built against that schema and continues to read anything
    written in it (noctalia, a future swaync bridge, our own writer).
    """
    payload = {
        "notifications": [
            {
                "id": "deadbeefcafef00d" + "0" * 48,
                "appName": "Slack",
                "summary": SEEDED_SUMMARY,
                "body": "hello pi, you should see me",
                "urgency": 1,
                "timestamp": 1779298950000,
                "actionsJson": "[]",
                "originalId": 1,
            }
        ]
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(payload, fh)


def collect_assistant_text(events):
    """Pull the final assistant message text out of agent_end.messages."""
    parts = []
    for ev in events:
        if ev.get("type") != "agent_end":
            continue
        for m in ev.get("messages") or []:
            if not isinstance(m, dict) or m.get("role") != "assistant":
                continue
            content = m.get("content")
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                for c in content:
                    if (
                        isinstance(c, dict)
                        and c.get("type") == "text"
                        and (c.get("text") or "").strip()
                    ):
                        parts.append(c["text"])
    return "\n".join(parts)


def main():
    if len(sys.argv) != 6:
        fail(
            "usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> "
            "<notifications_bin> <work_dir>"
        )
    pi_bin, mock_script, ext_dir, notifications_bin, work_dir = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)

    agent_dir = os.path.join(work_dir, "agent")
    os.makedirs(agent_dir, exist_ok=True)

    # bash-confirm extension + an allowlist that mirrors what the
    # pi-chat module ships in production. If the allowlist regex breaks
    # we want this test to scream rather than the user discover it via
    # an unexpected confirm prompt.
    settings = {
        "extensions": [
            os.path.join(ext_dir, "bash-confirm.ts"),
            os.path.join(ext_dir, "llama-swap-discover.ts"),
        ],
        "defaultProvider": "local",
        "defaultModel": "mock-notifications-model",
        "quietStartup": True,
        "enableInstallTelemetry": False,
    }
    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(settings, fh)
    with open(os.path.join(agent_dir, "bash-confirm.json"), "w") as fh:
        json.dump({"allowPatterns": ["^notifications(\\s|$)"]}, fh)

    # Seed the notifications history file in a location the CLI can read
    # via DISTRO_NOTIFICATIONS_FILE.
    notifications_file = os.path.join(work_dir, "notifications", "history.json")
    seed_notifications(notifications_file)

    # Stage the CLI on PATH. `notifications_bin` resolves to the wrapper
    # inside the package's bin dir; we expose just that dir on PATH so
    # pi's bash subprocess can invoke it by name.
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    staged = os.path.join(bin_dir, "notifications")
    if not os.path.exists(staged):
        os.symlink(notifications_bin, staged)

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
                "DISTRO_NOTIFICATIONS_FILE": notifications_file,
                "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            }
        )
        cwd = os.path.join(work_dir, "cwd")
        os.makedirs(cwd, exist_ok=True)
        pi = PiClient(pi_bin, env, cwd)
        try:
            pi.send(
                {
                    "type": "prompt",
                    "message": "list my recent desktop notifications please",
                }
            )
            events = pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)

            prompts = [e for e in events if e.get("type") == "extension_ui_request"]
            if prompts:
                fail(
                    "bash-confirm prompted for a whitelisted `notifications` "
                    f"command — allowlist plumbing is broken: {prompts!r}"
                )

            tool_starts = [e for e in events if e.get("type") == "tool_execution_start"]
            if not tool_starts:
                fail(f"pi never executed a tool: {events!r}")

            text = collect_assistant_text(events)
            if SEEDED_SUMMARY not in text:
                fail(
                    "assistant text does not contain the seeded notification "
                    f"summary {SEEDED_SUMMARY!r}; got: {text!r}"
                )
        finally:
            pi.close()
    finally:
        mock.terminate()
        try:
            mock.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock.kill()
    print("OK")


if __name__ == "__main__":
    main()
