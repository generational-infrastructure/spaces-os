#!/usr/bin/env python3
"""Contract test: a model picked in the panel persists.

The Panel's header combobox calls PiSession.setModel(provider, id) —
fire-and-forget — on the LIVE object. The session ENTRY (entry.model in
sessionsList / sessions.json) is the durable carrier: the reconciler
re-asserts obj.modelPref from entry.model on EVERY sessionsList
reassignment, and a panel restart rebuilds every PiSession from the
entry alone. So a pick that only lands on the live object is broken
twice over:

  1. any later list reassignment (new chat, unread bump, rename,
     remote import) silently reverts the live modelPref to the stale
     entry value — the "new chat / any activity falls back to the
     default model" bug;
  2. sessions.json never learns the pick, so a panel restart shows the
     chat history but runs the default model.

Drives the real PiChatBackend (headless quickshell) against the mock
pi-sessiond from the restart-preserves-model check. Sequence:

  1. newSession (no explicit model; empty frecency store → entry.model
     ""), spawn, wait for the daemon attach.
  2. setModel("mock", "test-model") — the Panel's picker path.
  3. Assert the ENTRY now carries model="mock/test-model" (the
     write-through under test).
  4. newSession #2 — reassigns sessionsList, running the reconciler.
     Assert session #1's LIVE modelPref survived (no clobber).
  5. Assert sessions.json on disk carries the pick for session #1
     (restart persistence).

No real pi/LLM/VM. ~10-20s.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir> <mock_daemon>
"""

from __future__ import annotations

import json
import os
import sys

from qs_harness import (
    Quickshell,
    fail,
    qs_env,
    reap,
    spawn,
    stage_shell,
    wait_until,
)

TOKEN = "modelpick-secret"
MODEL_PROVIDER = "mock"
MODEL_ID = "test-model"
MODEL_PREF = f"{MODEL_PROVIDER}/{MODEL_ID}"


def main() -> None:
    if len(sys.argv) != 6:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir> <mock>")
    qs_bin, test_dir, plugin_dir, work_dir, mock_daemon = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)

    # Seed sessions.json so FileView.onLoaded fires and _loadFromAdapter
    # runs (arming the importer cutoff), plus an EMPTY frecency store so
    # newSession has nothing to inherit and entry.model starts "".
    state_dir = os.path.join(work_dir, ".local", "state", "spaces", "pi")
    os.makedirs(state_dir, exist_ok=True)
    sessions_path = os.path.join(state_dir, "sessions.json")
    with open(sessions_path, "w") as fh:
        json.dump(
            {
                "version": 1,
                "sessions": [],
                "activeSessionId": "",
                "lastImportTime": 1000,
            },
            fh,
        )
    with open(os.path.join(state_dir, "model-frecency.json"), "w") as fh:
        fh.write('{"version":1,"models":{}}')

    frames_log = os.path.join(work_dir, "frames.log")
    open(frames_log, "w").close()

    mock_proc = spawn(
        [sys.executable, mock_daemon, frames_log, "remote", TOKEN],
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

    executors_json = json.dumps([{"id": "remote", "url": daemon_url(), "token": TOKEN}])

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_EXECUTORS": executors_json,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:modelpick")
    qs.start()

    def ipc(*args):
        return qs.ipc(*args, timeout=20)

    def raw_sessions():
        return json.loads(ipc("rawSessions"))

    def entry(sid):
        return next((s for s in raw_sessions() if s["id"] == sid), None)

    def die(msg):
        qs.dump_logs(extra=("mock-daemon.log", "frames.log"))
        try:
            sys.stderr.write("\n== final index ==\n")
            sys.stderr.write(json.dumps(raw_sessions(), indent=2) + "\n")
        except Exception as e:
            sys.stderr.write(f"(could not read index: {e})\n")
        fail(msg)

    try:
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the test:modelpick IPC target")

        if not wait_until(
            lambda: ipc("executorConnected", "remote") == "true",
            timeout_s=30,
        ):
            die("panel never connected to the remote executor")

        # ── mint + attach session #1 ─────────────────────────────────────
        sid = ipc("newSession", "PickChat", "remote")
        if not sid:
            die("newSession returned no id")
        ipc("spawnSession", sid)
        if not wait_until(
            lambda: (entry(sid) or {}).get("daemonSessionId"), timeout_s=30
        ):
            die("session never attached — entry has no daemonSessionId")
        if entry(sid)["model"] != "":
            die(f"precondition: fresh entry.model should be '', got {entry(sid)!r}")

        # ── the Panel's picker path ──────────────────────────────────────
        ipc("setModel", sid, MODEL_PROVIDER, MODEL_ID)

        # (1) Write-through: the ENTRY is the durable carrier.
        if not wait_until(
            lambda: (entry(sid) or {}).get("model") == MODEL_PREF, timeout_s=10
        ):
            die(
                "setModel never wrote through to the session entry: "
                f"entry.model={entry(sid) and entry(sid)['model']!r}, "
                f"expected {MODEL_PREF!r}"
            )

        # (2) No reconciler clobber: a list reassignment (new chat) must
        # not revert the live modelPref.
        sid2 = ipc("newSession", "SecondChat", "remote")
        if not sid2:
            die("second newSession returned no id")
        pref = ipc("modelPrefOf", sid)
        if pref != MODEL_PREF:
            die(
                "reconciler clobbered the live modelPref after a list "
                f"reassignment: got {pref!r}, expected {MODEL_PREF!r}"
            )

        # (3) Restart persistence: sessions.json carries the pick.
        def persisted_model():
            try:
                with open(sessions_path) as fh:
                    data = json.load(fh)
            except (OSError, ValueError):
                return None
            for s in data.get("sessions", []):
                if s.get("id") == sid:
                    return s.get("model")
            return None

        if not wait_until(lambda: persisted_model() == MODEL_PREF, timeout_s=10):
            die(
                "sessions.json never learned the pick: "
                f"persisted model={persisted_model()!r}, expected {MODEL_PREF!r}"
            )

        print("PASS: model pick writes through to entry + index and survives")
    finally:
        qs.stop()
        reap(mock_proc)


if __name__ == "__main__":
    main()
