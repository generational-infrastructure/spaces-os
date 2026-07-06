#!/usr/bin/env python3
"""Host-directive launch contract test.

Proves backend.launchBackground(prompt, {executor}) pins the launched
session to the named executor and refuses an unknown id rather than
silently launching on the default. No pi worker, no LLM: the executor
field is stamped synchronously by newSession, so the contract is a pure
data + control-flow assertion driven over test-only IPC verbs that call
the SAME backend function the quick-launch bar does.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import sys
import time

from qs_harness import Quickshell, fail, qs_env, stage_shell, wait_until

TARGET = "test:quick-launch-host"



def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target=TARGET)
    qs.start()

    def die(msg):
        qs.die(msg)

    def call(*args: str) -> str:
        return qs.ipc(*args, timeout=20)

    def executor_of(sid: str) -> str | None:
        for s in json.loads(call("dumpSessions")):
            if s["id"] == sid:
                return s["executor"]
        return None

    try:

        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the host IPC target")

        # Seed the executor inventory; confirm it took.
        seeded = json.loads(call("seedExecutors"))
        if seeded != ["kiwi", "traube"]:
            die(f"executor seed failed: {seeded!r}")
        # Two executors, no explicit default → the first configured
        # executor is the default. ("" is only the transient marker for
        # an unloaded/empty inventory; it no longer means "local pi".)
        if call("defaultExecutorId") != "kiwi":
            die(f"unexpected defaultExecutorId {call('defaultExecutorId')!r}")

        # (a) valid id pins the session.
        before = int(call("sessionCount"))
        sid = call("launchHost", "summarize logs", "kiwi")
        if not sid:
            die("launchHost returned no session id for a valid executor")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            die(f"valid launch created no session (count {call('sessionCount')})")
        if executor_of(sid) != "kiwi":
            die(f"session executor {executor_of(sid)!r}, want 'kiwi'")

        # (b) unknown id is REFUSED — no session, default not used.
        before = int(call("sessionCount"))
        bad = call("launchHost", "diagnose outage", "ghost")
        if bad != "":
            die(f"unknown executor launch returned id {bad!r}; expected refusal")
        time.sleep(0.5)
        if int(call("sessionCount")) != before:
            die("unknown executor launch created a session (should be refused)")

        # (c) a second valid id pins exactly (no cross-talk with the first).
        before = int(call("sessionCount"))
        sid2 = call("launchHost", "tidy up", "traube")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            die("second valid launch created no session")
        if executor_of(sid2) != "traube":
            die(f"second session executor {executor_of(sid2)!r}, want 'traube'")

        # (d) omitting the executor pins the session to the default
        # executor (the first configured one) at mint time.
        before = int(call("sessionCount"))
        sid3 = call("launchPlain", "no host here")
        if not wait_until(lambda: int(call("sessionCount")) == before + 1, timeout_s=5):
            die("plain launch created no session")
        if executor_of(sid3) != "kiwi":
            die(f"plain session executor {executor_of(sid3)!r}, want 'kiwi' (default)")

        print("PASS")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
