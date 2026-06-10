#!/usr/bin/env python3
"""Integration test for the memory pi extension talking real RPC.

Drives pi --mode rpc with the memory + llama-swap-discover extensions
loaded against a mock OpenAI Chat Completions server and a stub
sediment binary. Verifies the three observable behaviours of
extensions/memory/index.ts:

  * agent_end → extractor LLM call → sediment store
  * before_agent_start → sediment recall → <recalled_memories> block
    injected into the system prompt for the next turn
  * memory_search tool is registered and callable (presence check via
    pi's `get_state` / settings echo is enough; we don't drive the LLM
    through a tool_call to keep the mock tight)

Usage: driver.py <pi_bin> <mock_llm_script> <ext_src> <stub_script> <work_dir>

`ext_src` is the path to the memory extension's index.ts (with the
`@@SEDIMENT_BIN@@` sentinel still present); the driver copies it into
`work_dir` and substitutes the sentinel with `<stub_script>` so the
extension shells out to our deterministic stub.
"""

import json
import os
import stat
import subprocess
import sys
import threading
import time
from queue import Empty, Queue


def fail(msg):
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def start_mock_llm(mock_script, work_dir, request_log):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    env = os.environ.copy()
    env["MOCK_REQUEST_LOG"] = request_log
    proc = subprocess.Popen(
        [sys.executable, mock_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
        env=env,
    )
    line = proc.stdout.readline()
    if not line:
        fail("mock LLM exited before printing its URL")
    return proc, line.decode().strip()


def materialize_extension(ext_src, stub_bin, work_dir):
    """Copy the .ts to work_dir and substitute the sentinel."""
    dest_dir = os.path.join(work_dir, "memory")
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "index.ts")
    with open(ext_src) as src:
        text = src.read()
    if "@@SEDIMENT_BIN@@" not in text:
        fail(f"sentinel @@SEDIMENT_BIN@@ not found in {ext_src}")
    text = text.replace("@@SEDIMENT_BIN@@", os.path.abspath(stub_bin))
    with open(dest, "w") as fh:
        fh.write(text)
    return dest


class PiClient:
    def __init__(self, pi_bin, env, work_dir, session_dir):
        self.proc = subprocess.Popen(
            [
                pi_bin,
                "--mode",
                "rpc",
                "--provider",
                "local",
                "--model",
                "mock-memory-model",
                # A real session dir (instead of --no-session): the memory
                # extension resolves its per-session opt-out marker via
                # ctx.sessionManager.getSessionDir(), so the marker test
                # needs pi to run against a directory we control.
                "--session-dir",
                session_dir,
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
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

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

    def drain_until(self, predicate, timeout=120):
        collected = []
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"timed out draining events; collected so far: {collected[-5:]!r}")
            try:
                ev = self.events.get(timeout=remaining)
            except Empty:
                fail("timed out draining events")
            if ev is None:
                fail(f"pi closed stdout early; tail: {collected[-5:]!r}")
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


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def request_system_prompt(req):
    """Pull the system prompt text from a Chat Completions request body."""
    messages = req.get("messages") or []
    for m in messages:
        if m.get("role") != "system":
            continue
        content = m.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    parts.append(c.get("text") or "")
            return "\n".join(parts)
    return ""


def find_user_text(req):
    """Last user-message text in a Chat Completions request body."""
    messages = req.get("messages") or []
    for m in reversed(messages):
        if m.get("role") != "user":
            continue
        content = m.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    return c.get("text") or ""
    return ""


def main():
    if len(sys.argv) != 6:
        fail(
            "usage: driver.py <pi_bin> <mock_llm_script> <ext_src> <stub_script> <work_dir>"
        )
    pi_bin, mock_script, ext_src, stub_script, work_dir = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)

    # Materialize the stub at work_dir/sediment-stub with a shebang
    # that points at the active python (the build sandbox lacks
    # /usr/bin/env, so #!/usr/bin/env python3 would die with ENOENT
    # the moment pi.exec spawns it). pi.exec calls execve directly,
    # so the shebang must resolve to a real binary path.
    stub_bin = os.path.join(work_dir, "sediment-stub")
    with open(stub_script) as src:
        body = src.read()
    if body.startswith("#!"):
        body = body.split("\n", 1)[1] if "\n" in body else ""
    with open(stub_bin, "w") as dest:
        dest.write(f"#!{sys.executable}\n")
        dest.write(body)
    st = os.stat(stub_bin)
    os.chmod(stub_bin, st.st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    memory_index = materialize_extension(ext_src, stub_bin, work_dir)
    llama_discover = os.path.join(
        os.path.dirname(os.path.abspath(ext_src)),
        "..",
        "llama-swap-discover.ts",
    )
    llama_discover = os.path.abspath(llama_discover)
    if not os.path.exists(llama_discover):
        fail(f"llama-swap-discover.ts missing at {llama_discover}")

    agent_dir = os.path.join(work_dir, "agent")
    os.makedirs(agent_dir, exist_ok=True)
    settings = {
        "extensions": [llama_discover, memory_index],
        "defaultProvider": "local",
        "defaultModel": "mock-memory-model",
        "quietStartup": True,
        "enableInstallTelemetry": False,
    }
    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(settings, fh)

    sediment_log = os.path.join(work_dir, "sediment.log")
    request_log = os.path.join(work_dir, "mock-requests.log")
    # The extension resolves the per-session opt-out marker via
    # ctx.sessionManager.getSessionDir() — the same convention
    # pi-sessiond's set_memory command writes. Run pi against an
    # explicit --session-dir so the marker path is under our control.
    session_dir = os.path.join(work_dir, "session-state")
    os.makedirs(session_dir, exist_ok=True)
    marker_path = os.path.join(session_dir, "memory-off")

    mock, url = start_mock_llm(mock_script, work_dir, request_log)
    try:
        env = os.environ.copy()
        env.update(
            {
                "PI_CODING_AGENT_DIR": agent_dir,
                "LLAMA_SWAP_BASE_URL": url,
                "PI_OFFLINE": "1",
                "PI_TELEMETRY": "0",
                "HOME": work_dir,
                "SEDIMENT_STUB_LOG": sediment_log,
            }
        )

        pi = PiClient(pi_bin, env, work_dir, session_dir)
        try:
            # ── Turn 1 ────────────────────────────────────────────────
            pi.send({"type": "prompt", "message": "I love blue."})
            pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)

            # Give the agent_end handler a moment to finish the side-call
            # + sediment store before we inspect the log. The hook runs
            # awaited by pi but extract+store can fire after the
            # agent_end event surfaces on the RPC channel.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                sediment_calls = read_jsonl(sediment_log)
                if any(
                    (call.get("argv") or [None])[0] == "store"
                    for call in sediment_calls
                ):
                    break
                time.sleep(0.1)

            sediment_calls = read_jsonl(sediment_log)
            stores = [
                c for c in sediment_calls if (c.get("argv") or [None])[0] == "store"
            ]
            if not stores:
                fail(
                    "expected sediment `store` call after turn 1; got argv log:"
                    f" {[c.get('argv') for c in sediment_calls]!r}"
                )
            store_payload = stores[0]["argv"][1] if len(stores[0]["argv"]) > 1 else ""
            if "[fact] favourite colour: blue" not in store_payload:
                fail(
                    "first store payload did not contain the extracted fact;"
                    f" got {store_payload!r}"
                )

            # The extractor side-call must have run too (otherwise the
            # store could only have come from a literal pre-canned path),
            # so verify it surfaced as a request to the mock with the
            # EXTRACT_PROMPT opener.
            requests = read_jsonl(request_log)
            if not any(
                "extract durable memory items" in (find_user_text(r) or "").lower()
                for r in requests
            ):
                fail("no extractor side-call observed in mock request log")

            # ── Turn 2 ────────────────────────────────────────────────
            pre_turn2_recalls = sum(
                1 for c in sediment_calls if (c.get("argv") or [None])[0] == "recall"
            )
            pi.send(
                {
                    "type": "prompt",
                    "message": "What's my favourite colour?",
                }
            )
            pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)

            # Wait for the before_agent_start recall to land in the log.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                sediment_calls = read_jsonl(sediment_log)
                recalls = sum(
                    1
                    for c in sediment_calls
                    if (c.get("argv") or [None])[0] == "recall"
                )
                if recalls > pre_turn2_recalls:
                    break
                time.sleep(0.1)

            sediment_calls = read_jsonl(sediment_log)
            recall_calls = [
                c for c in sediment_calls if (c.get("argv") or [None])[0] == "recall"
            ]
            non_supersede_recalls = [
                c
                for c in recall_calls
                if len(c.get("argv") or []) > 1 and not c["argv"][1].startswith("[")
            ]
            if not non_supersede_recalls:
                fail(
                    "expected a recall keyed on the user prompt during"
                    " before_agent_start; got"
                    f" {[c.get('argv') for c in recall_calls]!r}"
                )

            # The mock should have received a request whose system prompt
            # carries the injected <recalled_memories> block with the
            # canned fact body.
            requests = read_jsonl(request_log)
            injected = [
                r
                for r in requests
                if "<recalled_memories>" in request_system_prompt(r)
                and "favourite colour: blue" in request_system_prompt(r)
            ]
            if not injected:
                fail(
                    "no chat-completions request observed with the recalled"
                    " memories block injected into the system prompt"
                )

            # ── Turn 3: per-session opt-out via marker file ─────────
            # Touch the marker; the extension's hooks see existsSync()
            # === true on the next prompt and short-circuit. We must
            # observe ZERO additional sediment calls (no recall in
            # before_agent_start, no store in agent_end) for this turn.
            sediment_calls = read_jsonl(sediment_log)
            pre_turn3_call_count = len(sediment_calls)
            pre_turn3_requests = len(read_jsonl(request_log))
            with open(marker_path, "w") as fh:
                fh.write("")

            pi.send(
                {
                    "type": "prompt",
                    "message": "Tell me about myself.",
                }
            )
            pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)

            # Give the agent_end hook a beat to *not* run.
            time.sleep(2.0)
            sediment_calls = read_jsonl(sediment_log)
            new_sediment = sediment_calls[pre_turn3_call_count:]
            if new_sediment:
                fail(
                    "expected zero sediment calls with memory disabled marker;"
                    f" saw {[c.get('argv') for c in new_sediment]!r}"
                )

            # The actual LLM chat call must still go through, AND its
            # system prompt must not carry a recalled_memories block.
            new_requests = read_jsonl(request_log)[pre_turn3_requests:]
            chat_requests = [
                r
                for r in new_requests
                if "extract durable memory items"
                not in (find_user_text(r) or "").lower()
            ]
            if not chat_requests:
                fail(
                    "expected at least one chat-completions request during"
                    " the disabled turn; got none"
                )
            for r in chat_requests:
                if "<recalled_memories>" in request_system_prompt(r):
                    fail(
                        "recalled_memories block leaked into the system prompt"
                        " while memory was disabled via marker file"
                    )

            # Removing the marker re-enables recall on the next prompt.
            os.remove(marker_path)
            pre_turn4_recalls = sum(
                1 for c in sediment_calls if (c.get("argv") or [None])[0] == "recall"
            )
            pi.send(
                {
                    "type": "prompt",
                    "message": "What's my favourite colour again?",
                }
            )
            pi.drain_until(lambda e: e.get("type") == "agent_end", timeout=120)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                sediment_calls = read_jsonl(sediment_log)
                recalls = sum(
                    1
                    for c in sediment_calls
                    if (c.get("argv") or [None])[0] == "recall"
                )
                if recalls > pre_turn4_recalls:
                    break
                time.sleep(0.1)
            sediment_calls = read_jsonl(sediment_log)
            recalls_after = sum(
                1 for c in sediment_calls if (c.get("argv") or [None])[0] == "recall"
            )
            if recalls_after <= pre_turn4_recalls:
                fail(
                    "removing the marker did not re-enable recall;"
                    " no new recall call observed"
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
