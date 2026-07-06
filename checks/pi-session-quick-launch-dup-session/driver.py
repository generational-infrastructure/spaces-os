#!/usr/bin/env python3
"""Quick-launch duplicate-session regression.

Drives the real PiChatBackend (headless quickshell) against a fake
pi-sessiond that, like the real daemon, broadcasts the §12 `sessions`
list immediately after each `create_session` ack. With a single REMOTE
executor configured this reproduces the duplicate-session bug.

Root cause: launchBackground (and any spawn()-then-send() pattern)
issues a SECOND spawn while the first create_session is still in
flight. Unless _wsSpawn's idempotency guard holds across that window
(_wsAttached still false), a second create_session goes out, the daemon
mints two sessions, and — since the panel entry can hold only one
daemonSessionId — the broadcast advertises an id the index doesn't
recognise, which _importRemoteSessions re-imports as a dead duplicate.
(It only bites a *returning* desktop: a pre-existing sessions.json is
what arms lastImportTime, without which the importer no-ops.)

Two assertions:

  (1) robustness — a remote session driven with the spawn()-then-send()
      double-spawn must mint ONE daemon session and leave EXACTLY ONE
      index entry (no orphan/duplicate): _wsSpawn must stay idempotent
      across the in-flight create window.

  (2) intent — backend.launchBackground() (the Mod+/ quick-bar path) must
      follow defaultExecutor: with a single remote executor configured and no
      explicit defaultExecutor, its session lands on that lone remote (executor
      "remote") and stays EXACTLY ONE entry through this path too.

The remote executor topology is injected as JSON via
$SPACES_PI_CHAT_EXECUTORS (the panel's test seam) since the root-owned
/etc/spaces/pi-chat.json can't be written in the build sandbox. A seeded
sessions.json mimics the returning desktop. No real pi/LLM/VM. ~10-20s.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import sys
import time

from qs_harness import (
    Quickshell,
    fail,
    qs_env,
    reap,
    spawn,
    stage_shell,
    wait_until,
)

TOKEN = "dup-secret"


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    # Seed a pre-existing sessions.json — the returning-desktop scenario. Its
    # presence is what makes FileView.onLoaded fire so _loadFromAdapter runs and
    # arms lastImportTime; on a fresh profile (no file) the importer stays
    # disarmed (lastImportTime == 0) and the bug can't show. The seeded value
    # itself is immaterial: the empty-sessions bootstrap re-arms the cutoff to
    # "now" at load time, still ahead of every session this run creates.
    state_dir = os.path.join(work_dir, ".local", "state", "spaces", "pi")
    os.makedirs(state_dir, exist_ok=True)
    with open(os.path.join(state_dir, "sessions.json"), "w") as fh:
        json.dump(
            {
                "version": 1,
                "sessions": [],
                "activeSessionId": "",
                "lastImportTime": 1000,
            },
            fh,
        )

    # The mock binds an ephemeral port and prints `ws://127.0.0.1:<port>` as
    # its first output line (now captured in mock-daemon.log).
    mock_proc = spawn(
        [
            sys.executable,
            os.path.join(test_dir, "mock-daemon.py"),
            "remote",
            TOKEN,
        ],
        work_dir,
        "mock-daemon.log",
    )

    def daemon_url():
        try:
            with open(os.path.join(work_dir, "mock-daemon.log")) as fh:
                for raw in fh:
                    line = raw.strip()
                    if line.startswith("ws://"):
                        return line
        except OSError:
            pass
        return None

    if not wait_until(lambda: daemon_url() is not None, timeout_s=15):
        fail("mock daemon did not print its URL")
    ws_url = daemon_url()

    # Inject ONE remote executor, no defaultExecutor — so defaultExecutorId
    # silently resolves to it, the exact "single remote executor" topology the
    # bug needs. Passed as JSON via $SPACES_PI_CHAT_EXECUTORS (the panel's
    # test seam) since /etc/spaces/pi-chat.json is root-owned + unwritable here.
    executors_json = json.dumps([{"id": "remote", "url": ws_url, "token": TOKEN}])

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_EXECUTORS": executors_json,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:dup")
    qs.start()

    def ipc(*args):
        return qs.ipc(*args, timeout=20)

    def raw_sessions():
        return json.loads(ipc("rawSessions"))

    def die(msg):
        qs.dump_logs(extra=("mock-daemon.log",))
        try:
            sys.stderr.write("\n== final index ==\n")
            sys.stderr.write(json.dumps(raw_sessions(), indent=2) + "\n")
        except Exception as e:
            sys.stderr.write(f"(could not read index: {e})\n")
        fail(msg)

    try:
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the test:dup IPC target")

        if not wait_until(
            lambda: ipc("executorConnected", "remote") == "true",
            timeout_s=30,
        ):
            die("panel never connected to the remote executor")

        # ── (1) robustness: a remote session driven with launchBackground's
        # spawn()-then-send() double-spawn must mint exactly ONE daemon session
        # and leave exactly ONE index entry. The second spawn racing the first's
        # in-flight create_session is what orphans a second daemon session that
        # re-imports as the dead duplicate. ─────────────────────────────────
        sid = ipc("newSessionOn", "RemoteDouble", "remote")
        if not sid:
            die("newSessionOn returned no id")
        ipc("spawnSend", sid, "hi")

        # Wait for the streamed reply: by the time it lands, both create acks
        # and the `sessions` broadcasts have been processed, so any orphan/dup
        # has already materialised.
        if not wait_until(
            lambda: "Hello from the remote executor" in ipc("lastAssistantText", sid),
            timeout_s=60,
        ):
            die("remote session never received the streamed reply")

        # Settle so a deferred re-import can't sneak a duplicate in after the
        # count.
        time.sleep(1.5)

        sessions = raw_sessions()
        doubles = [s for s in sessions if s["name"] == "RemoteDouble"]
        if len(doubles) != 1:
            die(
                "spawn()+send() on a remote session double-created: expected exactly "
                f"ONE 'RemoteDouble' entry, got {len(doubles)}: {doubles!r}\n"
                f"full index: {sessions!r}"
            )

        # ── (2) intent: quick-bar follows defaultExecutor AND is single ─────
        # With one remote executor and no explicit defaultExecutor, the quick-bar
        # session lands on that lone remote ("remote"); dedup must hold through
        # launchBackground too, leaving exactly one entry. ───────────────────
        before = {s["id"] for s in sessions}
        qid = ipc("launchBackground", "quick task here")

        def quick_entries():
            out = [
                s
                for s in raw_sessions()
                if s["id"] not in before and s.get("name") == "quick task here"
            ]
            return out or None

        if not wait_until(lambda: quick_entries() is not None, timeout_s=10):
            die("launchBackground did not create a quick-bar session in the index")
        # Settle, then re-read so a deferred duplicate is counted.
        time.sleep(1.5)
        entries = [
            s
            for s in raw_sessions()
            if s["id"] not in before and s.get("name") == "quick task here"
        ]
        if len(entries) != 1:
            die(
                "quick-launch produced a duplicate: expected exactly ONE "
                f"'quick task here' entry, got {len(entries)}: {entries!r}"
            )
        entry = entries[0]
        if qid and entry["id"] != qid:
            sys.stderr.write(
                f"note: launchBackground returned {qid!r}, index shows {entry['id']!r}\n"
            )
        if entry["executor"] != "remote":
            die(
                "quick-bar session must follow defaultExecutor (the lone remote, "
                f'"remote"), got {entry["executor"]!r}: {entry!r}'
            )

        print("PASS")
    finally:
        qs.stop()
        reap(mock_proc)


if __name__ == "__main__":
    main()
