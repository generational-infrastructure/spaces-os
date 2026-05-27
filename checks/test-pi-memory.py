#!/usr/bin/env python3
"""End-to-end exercise of the pi-chat memory extension.

Runs the full cross-session recall loop against a live VM:

  1. Send "I love mountain biking. …" on the active session and wait
     for the mock LLM to acknowledge.
  2. Poll the user's shared sediment DB until the agent_end hook has
     extracted + stored the `pref | hobby | mountain biking` fact.
  3. Open a NEW chat session through the plugin's IPC, send
     "What's my hobby?", and wait for a reply that contains
     "mountain biking" — proving the before_agent_start hook recalled
     the fact from the prior session and injected it into the new
     session's system prompt, which the mock LLM echoed back.

Asserts both halves:
  - storage path (sediment list shows the item),
  - recall path (the second-session reply carries the body verbatim).

A regression in either hook fails this loudly. The pre-baked
embedding model in $HF_HOME means no network is touched.

Usage: test-pi-memory.py <quickshell_bin> <shell_config> <target>
"""

import json
import os
import subprocess
import sys
import time

TRIGGER_PHRASE = "I love mountain biking. Remember that for next time."
QUERY_PHRASE = "What's my hobby?"
FACT_BODY = "mountain biking"


def call(quickshell_bin, config, target, fn, *args, timeout=15):
    res = subprocess.run(
        [quickshell_bin, "ipc", "-c", config, "call", target, fn, *map(str, args)],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if res.returncode != 0:
        sys.exit(
            f"ipc {fn}({args!r}) failed: rc={res.returncode}"
            f" stderr={res.stderr!r} stdout={res.stdout!r}"
        )
    return res.stdout.strip()


def poll_reply(
    quickshell_bin, config, target, session_id, baseline, predicate, timeout=60
):
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        last = call(quickshell_bin, config, target, "lastAssistantText", session_id)
        if last != baseline and predicate(last):
            return last
        time.sleep(0.5)
    sys.exit(
        f"timed out polling lastAssistantText for session={session_id!r};"
        f" baseline={baseline!r} last={last!r}"
    )


def _sediment_env():
    """Read /etc/distro/pi-chat.json so the sediment CLI sees the same
    DB + HF cache the chat sandbox uses. sudo strips
    environment.sessionVariables, so falling back to the in-process env
    would point at sediment's default ~/.sediment/data (empty) and
    trigger a model download against the public internet."""
    env = dict(os.environ)
    try:
        with open("/etc/distro/pi-chat.json") as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return env
    db_rel = cfg.get("memoryDbDir") or ""
    hf_home = cfg.get("memoryHfHome") or ""
    if db_rel:
        home = os.environ.get("HOME", "")
        # SEDIMENT_DB lives one level under memoryDbDir so the bind-
        # mounted leaf dir holds both the LanceDB tree (in /data) and
        # the access.db sediment puts in db_path.parent().
        env["SEDIMENT_DB"] = os.path.join(home, db_rel.lstrip("/"), "data")
    if hf_home:
        env["HF_HOME"] = hf_home
    return env


def sediment_list_json():
    """Snapshot of every stored memory item via the on-PATH sediment CLI."""
    # Memory extension writes facts with --scope global; sediment's
    # `list` defaults to --scope project. Ask for everything so the
    # globally-scoped items show up.
    res = subprocess.run(
        ["sediment", "list", "--scope", "all", "--json"],
        capture_output=True,
        text=True,
        timeout=20,
        env=_sediment_env(),
    )
    if res.returncode != 0:
        sys.exit(
            f"`sediment list --json` failed: rc={res.returncode} stderr={res.stderr!r}"
        )
    return json.loads(res.stdout or "[]")


def wait_for_stored_fact(timeout=120):
    """Block until `sediment list` returns at least one item that mentions
    FACT_BODY. The agent_end → extractor → sediment store chain is
    asynchronous, so we poll rather than assume timing."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        items = sediment_list_json()
        for it in items if isinstance(items, list) else items.get("items", []):
            content = json.dumps(it).lower()
            if FACT_BODY in content:
                return it
        last = items
        time.sleep(1.0)
    sys.exit(
        f"timed out waiting for `{FACT_BODY}` to land in sediment;"
        f" last snapshot={last!r}"
    )


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: test-pi-memory.py <quickshell_bin> <shell_config> <target>")
    quickshell_bin, config, target = sys.argv[1], sys.argv[2], sys.argv[3]

    # ── Session A: state the fact, wait for storage. ────────────────
    sessions = json.loads(call(quickshell_bin, config, target, "listSessions") or "[]")
    if not sessions:
        sys.exit(f"no sessions to drive: {sessions!r}")
    session_a = next(
        (s["id"] for s in sessions if s.get("active")),
        sessions[0]["id"],
    )
    print(f"SESSION A: {session_a}", file=sys.stderr)

    baseline_a = call(quickshell_bin, config, target, "lastAssistantText", session_a)
    call(quickshell_bin, config, target, "sendTo", session_a, TRIGGER_PHRASE)
    reply_a = poll_reply(
        quickshell_bin,
        config,
        target,
        session_a,
        baseline_a,
        predicate=lambda t: FACT_BODY in t.lower(),
    )
    print(f"STORE TURN OK: {reply_a[:120]!r}")

    stored = wait_for_stored_fact()
    print(f"STORED: {json.dumps(stored)[:200]}")

    # ── Session B: fresh chat, query memory. ────────────────────────
    session_b = call(quickshell_bin, config, target, "newSession", "memory-recall")
    if not session_b:
        sys.exit("newSession returned empty id")
    if session_b == session_a:
        sys.exit(f"newSession returned the active id: {session_b!r}")
    print(f"SESSION B: {session_b}", file=sys.stderr)

    baseline_b = call(quickshell_bin, config, target, "lastAssistantText", session_b)
    call(quickshell_bin, config, target, "sendTo", session_b, QUERY_PHRASE)
    reply_b = poll_reply(
        quickshell_bin,
        config,
        target,
        session_b,
        baseline_b,
        predicate=lambda t: FACT_BODY in t.lower(),
        timeout=90,
    )
    print(f"RECALL TURN OK: {reply_b[:120]!r}")

    if FACT_BODY not in reply_b.lower():
        sys.exit(
            f"recall regression: session B reply did not surface {FACT_BODY!r}:"
            f" reply={reply_b!r}"
        )

    print("SUCCESS")


if __name__ == "__main__":
    main()
