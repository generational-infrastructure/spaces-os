#!/usr/bin/env python3
"""New-chat model inheritance contract test.

A new chat session created without an explicit model must default to
the model the user most recently selected, the max-lastUsed key in
the persisted frecency store. PiSession is WS-only: the inherited
model rides the create_session envelope itself (model="provider/id"),
so the daemon session comes up on it — no set_model replay, no
fire-and-forget race for the first prompt to lose.

The frecency store is seeded so "local/old-favourite" has a far
higher score but "local/mock-model" has the later lastUsed.
Inheritance must follow recency, not score. Phases:

  1. The remote-import seam. _freshSessionEntry() keeps model "" so
     auto-imported daemon sessions do not inherit a local pick.
  2. newSession() persists entry.model == "local/mock-model".
  3. First prompt spawns the session: the create_session envelope on
     the wire carries model == "local/mock-model", and the prompt
     command follows it.

Drives the real PiChatBackend (headless quickshell) against a mock
pi-sessiond (injected via $SPACES_PI_CHAT_EXECUTORS) that logs every
frame in order. No real pi/LLM, no compositor, no VM. ~10-20s.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
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

DAY = 86400000
T0 = 1_700_000_000_000
INHERITED = "local/mock-model"
TOKEN = "inherits-secret"


def read_frames(frames_log: str) -> list[dict]:
    """Ordered {dir, frame} records the mock daemon witnessed."""
    if not os.path.exists(frames_log):
        return []
    out: list[dict] = []
    with open(frames_log) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                out.append({"__raw__": line})
    return out


def recv_frames(frames_log: str) -> list[dict]:
    return [r["frame"] for r in read_frames(frames_log) if r.get("dir") == "recv"]


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    # Seed the backend's state dir: a sessions.json baseline so
    # FileView.onLoaded fires (arming the importer cutoff), plus the
    # frecency store. old-favourite has a far higher score but
    # mock-model has the later lastUsed. A score-based pick would
    # choose old-favourite, since 50 decayed over one 3-day half-life
    # is still ~39 > 1.
    state_dir = os.path.join(work_dir, ".local", "state", "spaces", "pi")
    os.makedirs(os.path.join(state_dir, "sessions"), exist_ok=True)
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
    with open(os.path.join(state_dir, "model-frecency.json"), "w") as fh:
        json.dump(
            {
                "version": 1,
                "models": {
                    "local/old-favourite": {"score": 50, "lastUsed": T0},
                    "local/mock-model": {"score": 1, "lastUsed": T0 + DAY},
                },
            },
            fh,
        )

    frames_log = os.path.join(work_dir, "frames.log")
    open(frames_log, "w").close()

    # The mock binds an ephemeral port and prints `ws://127.0.0.1:<port>` as
    # its first output line (now captured in mock-daemon.log).
    mock_proc = spawn(
        [
            sys.executable,
            os.path.join(test_dir, "mock-daemon.py"),
            frames_log,
            "remote",
            TOKEN,
        ],
        work_dir,
        "mock-daemon.log",
    )

    def daemon_url():
        try:
            with open(os.path.join(work_dir, "mock-daemon.log")) as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith("ws://"):
                        return line
        except OSError:
            pass
        return None

    if not wait_until(lambda: daemon_url() is not None, timeout_s=15):
        fail("mock daemon did not print its URL")
    ws_url = daemon_url()

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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:new-chat-model")
    qs.start()

    def ipc(*args):
        return qs.ipc(*args, timeout=20)

    def die(msg: str) -> None:
        qs.dump_logs(extra=("mock-daemon.log", "frames.log"))
        sessions_json = os.path.join(state_dir, "sessions.json")
        if os.path.exists(sessions_json):
            sys.stderr.write("\n== sessions.json ==\n")
            sys.stderr.write(open(sessions_json).read())
        fail(msg)

    def persisted_entry(sid: str):
        path = os.path.join(state_dir, "sessions.json")
        if not os.path.exists(path):
            return None
        try:
            with open(path) as fh:
                data = json.load(fh)
        except json.JSONDecodeError:
            return None
        for s in data.get("sessions", []):
            if s.get("id") == sid:
                return s
        return None

    try:
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the test:new-chat-model IPC target")

        if not wait_until(
            lambda: ipc("executorConnected", "remote") == "true",
            timeout_s=30,
        ):
            die("panel never connected to the mock executor")

        # ModelFrecency's startup FileView load is async. Wait for the
        # seeded store to land before newSession() consults it.
        if not wait_until(
            lambda: int(ipc("frecencyLoadGen")) >= 1,
            timeout_s=10,
        ):
            die("ModelFrecency startup FileView load never completed")

        # (1) Remote-import seam. Entries minted via _freshSessionEntry
        # (the _importRemoteSessions shape) keep model "".
        fresh = ipc("freshEntryModel")
        if fresh != "<empty>":
            die(f"_freshSessionEntry inherited a model: {fresh!r} (must stay '')")

        # (2) newSession() inherits the most recently selected model and
        # persists it on the index entry.
        sid = ipc("newSession", "inherit-test")
        if not sid:
            die("newSession returned no id")
        found = {}

        def entry_persisted():
            e = persisted_entry(sid)
            if e is not None:
                found["entry"] = e
            return e is not None

        if not wait_until(entry_persisted, timeout_s=10):
            die(f"session {sid!r} never appeared in sessions.json")
        entry = found["entry"]
        if entry.get("model") != INHERITED:
            die(
                f"new session inherited {entry.get('model')!r}, expected "
                f"{INHERITED!r} (most recent pick; old-favourite has the "
                f"higher score but the older lastUsed)"
            )

        # (3) First prompt spawns the session. The create_session
        # envelope itself must carry the inherited model — that is the
        # WS transport's race-free equivalent of the old post-spawn
        # set_model: the daemon session comes up on the right model
        # before any prompt can run.
        ipc("sendTo", sid, "first prompt")

        def create_frame():
            return next(
                (
                    f
                    for f in recv_frames(frames_log)
                    if f.get("kind") == "create_session"
                ),
                None,
            )

        if not wait_until(lambda: create_frame() is not None, timeout_s=15):
            die("no create_session ever reached the mock daemon")
        create = create_frame()
        if create.get("model") != INHERITED:
            die(
                f"create_session carried model {create.get('model')!r}, "
                f"expected {INHERITED!r}: {json.dumps(create, indent=2)}"
            )

        def prompt_frame():
            for f in recv_frames(frames_log):
                if (
                    f.get("kind") == "command"
                    and (f.get("payload") or {}).get("type") == "prompt"
                ):
                    return f
            return None

        if not wait_until(lambda: prompt_frame() is not None, timeout_s=15):
            die(
                "prompt never reached the daemon after the create: "
                f"{json.dumps(recv_frames(frames_log), indent=2)}"
            )
        kinds = [f.get("kind") for f in recv_frames(frames_log)]
        if kinds.index("create_session") > kinds.index("command"):
            die(f"prompt went out before create_session: {kinds}")

        print("PASS")
    finally:
        qs.stop()
        reap(mock_proc)


if __name__ == "__main__":
    main()
