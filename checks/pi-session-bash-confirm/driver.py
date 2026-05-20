#!/usr/bin/env python3
"""Integration test for the bash-confirm pi extension talking real RPC.

Spawns a mock OpenAI Chat Completions server, then drives pi --mode rpc
with the bash-confirm + llama-swap-discover extensions loaded. Sends a
prompt, expects an `extension_ui_request{method:"confirm"}` for the
mock's bash tool call, answers it, and asserts the agent_end follows.

Runs the same scenario twice:
  - confirmed=true   → pi executes bash, mock's follow-up text arrives
  - confirmed=false  → pi blocks, mock's follow-up still produces text
                       (pi feeds the block reason back as a tool result)

Usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> <work_dir>

`ext_dir` is the directory holding bash-confirm.ts and
llama-swap-discover.ts (= modules/nixos/pi-chat/extensions/).
"""

import json
import os
import subprocess
import sys
import threading
import time
from queue import Empty, Queue


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
                "mock-bash-model",
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
        self.events.put(None)  # EOF sentinel

    def _read_stderr(self):
        for raw in self.proc.stderr:
            self._stderr_log.write(raw)
            self._stderr_log.flush()

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def wait_for(self, predicate, timeout=60):
        """Drain events until predicate(ev) is truthy. Returns matched event."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("timed out waiting for matching event")
            try:
                ev = self.events.get(timeout=remaining)
            except Empty:
                fail("timed out waiting for matching event")
            if ev is None:
                fail("pi process closed stdout before predicate matched")
            if predicate(ev):
                return ev

    def drain_until(self, predicate, timeout=60):
        """Collect events until predicate(ev) is truthy. Returns the list."""
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


def run_scenario(pi_bin, env, work_dir, confirmed):
    cwd = os.path.join(work_dir, f"cwd-{int(confirmed)}")
    os.makedirs(cwd, exist_ok=True)
    pi = PiClient(pi_bin, env, cwd)
    try:
        pi.send({"type": "prompt", "message": "please run a bash command"})

        # Either confirm bubble arrives → respond → wait for agent_end,
        # or agent_end arrives before confirm (would be a bug).
        ev = pi.wait_for(
            lambda e: (
                e.get("type") in ("extension_ui_request", "agent_end")
                or (
                    e.get("type") == "response"
                    and e.get("command") == "prompt"
                    and not e.get("success")
                )
            ),
            timeout=120,
        )

        if ev.get("type") == "response" and not ev.get("success"):
            fail(f"pi rejected prompt: {ev.get('error')}")

        if ev.get("type") != "extension_ui_request":
            fail(
                f"expected extension_ui_request, got {ev}. The extension hook "
                "may not be loaded."
            )

        if ev.get("method") != "confirm":
            fail(f"expected method=confirm, got method={ev.get('method')}")

        if "bash" not in (ev.get("message") or ""):
            fail(
                f"confirm body should mention the bash command, got: {ev.get('message')!r}"
            )

        pi.send(
            {
                "type": "extension_ui_response",
                "id": ev["id"],
                "confirmed": confirmed,
            }
        )

        events = pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)
        # Pi should produce at least one tool_execution_start (allowed
        # case) OR a notice (denied case). Either way the conversation
        # ends with an assistant text — the mock returns one once it
        # sees the tool result.
        text_seen = False
        for e in events:
            if e.get("type") == "message_update":
                me = e.get("assistantMessageEvent") or {}
                if me.get("type") in ("text_delta", "text_end"):
                    text_seen = True
            if e.get("type") == "agent_end":
                msgs = e.get("messages") or []
                for m in msgs:
                    if not isinstance(m, dict):
                        continue
                    if m.get("role") == "assistant":
                        content = m.get("content")
                        if isinstance(content, list):
                            for c in content:
                                if (
                                    isinstance(c, dict)
                                    and c.get("type") == "text"
                                    and (c.get("text") or "").strip()
                                ):
                                    text_seen = True
        if not text_seen:
            fail(f"no assistant text observed for confirmed={confirmed}: {events!r}")
    finally:
        pi.close()


def run_scenario_allowed(pi_bin, env, work_dir):
    """Allowlist matches the mock's bash command → no confirm prompt at all.

    Pi should jump straight from `prompt` to executing the tool call, the
    mock returns its follow-up text, and the agent_end carries assistant
    text. If an extension_ui_request slips through, the allowlist plumbing
    is broken — fail loudly.
    """
    cwd = os.path.join(work_dir, "cwd-allowed")
    os.makedirs(cwd, exist_ok=True)
    pi = PiClient(pi_bin, env, cwd)
    try:
        pi.send({"type": "prompt", "message": "please run a bash command"})
        events = pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)
        prompts = [e for e in events if e.get("type") == "extension_ui_request"]
        if prompts:
            fail(
                "allowlist scenario produced unexpected extension_ui_request(s); "
                f"the bash-confirm allowlist is not being honored: {prompts!r}"
            )
        text_seen = False
        for e in events:
            if e.get("type") == "message_update":
                me = e.get("assistantMessageEvent") or {}
                if me.get("type") in ("text_delta", "text_end"):
                    text_seen = True
            if e.get("type") == "agent_end":
                for m in e.get("messages") or []:
                    if not isinstance(m, dict) or m.get("role") != "assistant":
                        continue
                    content = m.get("content")
                    if not isinstance(content, list):
                        continue
                    for c in content:
                        if (
                            isinstance(c, dict)
                            and c.get("type") == "text"
                            and (c.get("text") or "").strip()
                        ):
                            text_seen = True
        if not text_seen:
            fail(f"no assistant text observed for allowlist scenario: {events!r}")
    finally:
        pi.close()


def main():
    if len(sys.argv) != 5:
        fail("usage: driver.py <pi_bin> <mock_llm_script> <ext_dir> <work_dir>")
    pi_bin, mock_script, ext_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)
    agent_dir = os.path.join(work_dir, "agent")
    os.makedirs(agent_dir, exist_ok=True)

    # Materialize a minimal settings.json that pulls in our extensions.
    settings = {
        "extensions": [
            os.path.join(ext_dir, "bash-confirm.ts"),
            os.path.join(ext_dir, "llama-swap-discover.ts"),
        ],
        "defaultProvider": "local",
        "defaultModel": "mock-bash-model",
        "quietStartup": True,
        # Stay strictly local — the sandbox has no network.
        "enableInstallTelemetry": False,
    }
    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(settings, fh)

    # Second agent dir wired with a bash-confirm.json allowlist that
    # matches the mock's "printf hello-from-bash" command exactly. The
    # plain confirm scenarios reuse `agent_dir`, which never sees this
    # file, so the order is independent.
    allow_dir = os.path.join(work_dir, "agent-allow")
    os.makedirs(allow_dir, exist_ok=True)
    with open(os.path.join(allow_dir, "settings.json"), "w") as fh:
        json.dump(settings, fh)
    with open(os.path.join(allow_dir, "bash-confirm.json"), "w") as fh:
        json.dump({"allowPatterns": ["^printf hello-from-bash$"]}, fh)

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
        run_scenario(pi_bin, env, work_dir, confirmed=True)
        run_scenario(pi_bin, env, work_dir, confirmed=False)
        allow_env = dict(env, PI_CODING_AGENT_DIR=allow_dir)
        run_scenario_allowed(pi_bin, allow_env, work_dir)
    finally:
        mock.terminate()
        try:
            mock.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock.kill()
    print("OK")


if __name__ == "__main__":
    main()
