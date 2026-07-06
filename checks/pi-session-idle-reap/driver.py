#!/usr/bin/env python3
"""WS-era idle-reap contract test.

PiSession no longer spawns a local pi worker — every session lives in a
pi-sessiond executor reached over WebSocket. The reaper moved with it:
PiChatBackend._reapIdle() calls PiSession.stop() on idle streaming
sessions, which sends a `detach` frame for the session's daemon id (and
drops the panel-side subscription); busy sessions and pending background
launches are skipped — no frame at all.

Two background launches share one backend, both landing on a mock
pi-sessiond that logs every inbound frame:

  * A: prompt contains "HOLD" — the mock streams the opening delta but
    never sends agent_end, so the turn stays in flight and the panel
    keeps busy=true (A is also still in _pendingBg: doubly exempt).
  * B: a quick prompt the mock completes (agent_end), so B ends up
    streaming-but-idle — exactly what the reaper exists to stop.

Then _reapIdle() runs (invoked directly through the IPC seam — no
waiting on the real idleTimeoutMinutes timer). Asserted off the mock's
frame log: a detach frame for B's daemon session id, NO detach for A's;
panel-side flags agree (B streaming=false, A streaming=true busy=true).

The executor topology is injected as JSON via $SPACES_PI_CHAT_EXECUTORS
(the panel's test seam) since the root-owned /etc/spaces/pi-chat.json
can't be written in the build sandbox. No real pi/LLM/daemon. ~10-20s.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import stat
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

TOKEN = "reap-secret"

REPLY = "Background task complete"


def stage_bin(work_dir: str) -> str:
    # B's completed background turn fires a notify-send toast; give the
    # backend a no-op stub so the Process spawn doesn't error in the sandbox.
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    stub = os.path.join(bin_dir, "notify-send")
    with open(stub, "w") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(stub, stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP)
    return bin_dir


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    frame_log = os.path.join(work_dir, "frames.jsonl")
    open(frame_log, "w").close()

    # The mock binds an ephemeral port and prints `ws://127.0.0.1:<port>` as
    # its first output line (now captured in mock-daemon.log).
    mock_proc = spawn(
        [
            sys.executable,
            os.path.join(test_dir, "mock-daemon.py"),
            "remote",
            TOKEN,
            frame_log,
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

    # One remote executor, no defaultExecutor — defaultExecutorId resolves to
    # it, so both launchBackground sessions land on the mock daemon.
    executors_json = json.dumps([{"id": "remote", "url": ws_url, "token": TOKEN}])

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(work_dir)

    env = qs_env(
        work_dir,
        extra={
            "PATH": bin_dir + os.pathsep + os.environ.get("PATH", ""),
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_EXECUTORS": executors_json,
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:reap")
    qs.start()

    def ipc(*args):
        return qs.ipc(*args, timeout=20)

    def read_frames():
        out = []
        with open(frame_log) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    def detach_sids():
        return {f.get("sessionId") for f in read_frames() if f.get("kind") == "detach"}

    def die(msg):
        sys.stderr.write("\n== frame log ==\n")
        try:
            sys.stderr.write(open(frame_log).read()[-4000:])
        except OSError as e:
            sys.stderr.write(f"(could not read frame log: {e})\n")
        qs.die(msg, extra_logs=("mock-daemon.log",))

    def raw_sessions():
        return json.loads(ipc("rawSessions"))

    try:
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the test:reap IPC target")

        if not wait_until(
            lambda: ipc("executorConnected", "remote") == "true",
            timeout_s=30,
        ):
            die("panel never connected to the remote executor")

        def session_ids():
            return {s["id"] for s in raw_sessions()}

        # ── A: the held background launch (busy + pending forever) ──
        base = session_ids()
        ipc("launchBackground", "HOLD a long running task")
        if not wait_until(lambda: bool(session_ids() - base), timeout_s=10):
            die("background launch A created no session")
        a_id = next(iter(session_ids() - base))
        if not wait_until(
            lambda: ipc("sessionBusy", a_id) == "true",
            timeout_s=30,
        ):
            die("session A never became busy (held turn)")

        # ── B: a quick launch that runs to completion ──
        base2 = session_ids()
        ipc("launchBackground", "quick ping")
        if not wait_until(lambda: bool(session_ids() - base2), timeout_s=10):
            die("background launch B created no session")
        b_id = next(iter(session_ids() - base2))
        # B finishes: agent_end clears busy, the reply streamed in.
        if not wait_until(
            lambda: (
                ipc("sessionBusy", b_id) == "false"
                and REPLY in ipc("lastAssistantText", b_id)
            ),
            timeout_s=60,
        ):
            die("session B never completed its turn")
        # B must still be attached (streaming) so the reaper has work to do.
        if ipc("sessionStreaming", b_id) != "true":
            die("session B detached before reap — nothing to reap")

        # Both entries need their daemon ids minted before the frame-log
        # assertions can be keyed.
        def daemon_ids():
            m = {s["id"]: s["daemonSessionId"] for s in raw_sessions()}
            a, b = m.get(a_id, ""), m.get(b_id, "")
            return (a, b) if a and b else None

        if not wait_until(lambda: daemon_ids() is not None, timeout_s=10):
            die(f"daemon session ids never materialised: {raw_sessions()!r}")
        a_sid, b_sid = daemon_ids()

        # No detach so far: nothing has been stopped yet.
        pre = detach_sids()
        if pre & {a_sid, b_sid}:
            die(f"unexpected detach frames before reap: {pre!r}")

        # ── the reaper runs ──
        ipc("reapIdle")

        # B (idle streaming) must be stopped: detach frame for its daemon id.
        if not wait_until(lambda: b_sid in detach_sids(), timeout_s=10):
            die(f"reaper sent no detach frame for the idle session B ({b_sid})")

        # A (busy + pending) must SURVIVE: no detach frame, still busy and
        # attached. Settle briefly so a late wrongful detach is counted.
        time.sleep(1.0)
        sids = detach_sids()
        if a_sid in sids:
            die(f"reaper detached the busy background launch A ({a_sid})")
        if ipc("sessionStreaming", b_id) != "false":
            die("session B still reports streaming after reap — stop() didn't land")
        if ipc("sessionStreaming", a_id) != "true":
            die("session A is no longer streaming after reap — it should survive")
        if ipc("sessionBusy", a_id) != "true":
            die("session A is no longer busy after reap — it was disturbed")

        print("PASS")
    finally:
        qs.stop()
        reap(mock_proc)


if __name__ == "__main__":
    main()
