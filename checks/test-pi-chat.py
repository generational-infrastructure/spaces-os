#!/usr/bin/env python3
"""End-to-end chat round-trip through the pi-chat standalone shell.

Drives the shell entirely via Quickshell IPC. The shell's
`send`/`lastAssistantText`/`listSessions` verbs are stable contract;
the underlying pi process is spawned lazily inside a systemd-run scope
the shell owns.

Usage: test-pi-chat.py <quickshell_bin> <shell_config> <target> [mode]

`shell_config` is the Quickshell config name (e.g. `pi-chat`).
`target` is the IpcHandler target string (e.g. `pi-chat`).
`mode` is "local" (default) or "openrouter". In openrouter mode the
llama-swap-specific model assertions are skipped.

Lives inside the VM. Run as the test user (XDG_RUNTIME_DIR must point
at the user manager's runtime dir).
"""

import json
import subprocess
import sys
import time


def call(quickshell_bin, config, target, fn, *args, timeout=10):
    """Invoke a shell IPC function and return its stdout-stripped text."""
    cmd = [
        quickshell_bin,
        "ipc",
        "-c",
        config,
        "call",
        target,
        fn,
        *(str(a) for a in args),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if res.returncode != 0:
        sys.exit(
            f"ipc call {fn}({', '.join(args)!r}) failed (code={res.returncode}): "
            f"stdout={res.stdout!r} stderr={res.stderr!r}"
        )
    return res.stdout.strip()


def poll_reply(
    quickshell_bin, config, target, session_id, baseline, predicate, timeout=30
):
    """Poll lastAssistantText until predicate(text) and text != baseline."""
    deadline = time.monotonic() + timeout
    last = baseline
    while time.monotonic() < deadline:
        reply = call(quickshell_bin, config, target, "lastAssistantText", session_id)
        if reply and reply != baseline and predicate(reply):
            return reply
        last = reply
        time.sleep(0.5)
    sys.exit(f"timed out polling lastAssistantText; last={last!r}")


def main():
    if len(sys.argv) < 4:
        sys.exit(
            "usage: test-pi-chat.py <quickshell_bin> <shell_config> <target> [mode]"
        )
    quickshell_bin = sys.argv[1]
    config = sys.argv[2]
    target = sys.argv[3]
    mode = sys.argv[4] if len(sys.argv) > 4 else "local"

    # Discover the initial session so subsequent polls have a stable id.
    raw = call(quickshell_bin, config, target, "listSessions")
    sessions = json.loads(raw or "[]")
    if not sessions:
        sys.exit(f"shell reported no sessions: {raw!r}")
    session_id = next(
        (s["id"] for s in sessions if s.get("active")),
        sessions[0]["id"],
    )
    print(f"SESSION: {session_id}", file=sys.stderr)

    # Turn 1: any non-empty reply is enough.
    baseline = call(quickshell_bin, config, target, "lastAssistantText", session_id)
    call(quickshell_bin, config, target, "send", "Hello bot")
    reply1 = poll_reply(
        quickshell_bin,
        config,
        target,
        session_id,
        baseline,
        predicate=lambda t: bool(t.strip()),
    )
    print(f"TURN 1 OK: {reply1[:80]!r}")

    # Turn 2: substantive content check. qwen2.5:0.5b with --temp 0
    # reliably says "blue" for the sky question.
    baseline = reply1
    call(
        quickshell_bin,
        config,
        target,
        "send",
        "What color is the sky? Answer in one word.",
    )
    reply2 = poll_reply(
        quickshell_bin,
        config,
        target,
        session_id,
        baseline,
        predicate=lambda t: "blue" in t.lower(),
    )
    print(f"TURN 2 OK: {reply2[:80]!r}")

    # Multi-session smoke test: open a fresh chat, ensure it lands as a
    # separate entry in listSessions and remains independent from the
    # default chat's history.
    new_id = call(quickshell_bin, config, target, "newSession", "harness-2")
    if not new_id:
        sys.exit("newSession returned empty id")
    sessions = json.loads(call(quickshell_bin, config, target, "listSessions") or "[]")
    if not any(s["id"] == new_id for s in sessions):
        sys.exit(f"new session not in listSessions: {sessions}")
    print(f"MULTI-SESSION OK: {len(sessions)} sessions total")

    # Original session should still hold turn-2's reply unchanged.
    snap = call(quickshell_bin, config, target, "lastAssistantText", session_id)
    if snap != reply2:
        sys.exit(
            f"original session bled into new session: snap={snap!r} reply2={reply2!r}"
        )

    if mode == "local":
        # qwen2.5:0.5b + smollm should both be discoverable via the
        # llama-swap-discover extension; pi exposes them through its
        # session's model registry. We can't read pi's registry over
        # IPC directly without adding more probes — settle for the
        # llama-swap endpoint, which is the source of truth.
        res = subprocess.run(
            ["curl", "--silent", "--fail", "http://127.0.0.1:8012/v1/models"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if res.returncode != 0:
            sys.exit(f"llama-swap /v1/models failed: {res.stderr}")
        models = json.loads(res.stdout)
        ids = sorted(m["id"] for m in models.get("data", []))
        for must_have in ("qwen2.5:0.5b", "smollm"):
            if must_have not in ids:
                sys.exit(f"{must_have} not in llama-swap models: {ids}")
        print(f"MODELS OK: {ids}")

    print("SUCCESS")


if __name__ == "__main__":
    main()
