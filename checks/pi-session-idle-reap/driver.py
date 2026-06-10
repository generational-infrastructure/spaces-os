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
import shutil
import stat
import subprocess
import sys
import time

TOKEN = "reap-secret"

REPLY = "Background task complete"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            v = predicate()
            if v:
                return v
        except Exception:
            pass
        time.sleep(interval_s)
    return None


def start_mock_daemon(mock_script: str, work_dir: str, frame_log: str):
    log = open(os.path.join(work_dir, "mock-daemon.log"), "w")
    proc = subprocess.Popen(
        [sys.executable, mock_script, "remote", TOKEN, frame_log],
        stdout=subprocess.PIPE,
        stderr=log,
    )
    line = proc.stdout.readline()
    if not line:
        fail("mock daemon did not print its URL")
    return proc, line.decode().strip()


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    shutil.copytree(plugin_dir, shell_root, dirs_exist_ok=True)
    for root, _dirs, files in os.walk(shell_root):
        os.chmod(root, 0o755)
        for f in files:
            try:
                os.chmod(os.path.join(root, f), 0o644)
            except OSError:
                pass
    shell_dst = os.path.join(shell_root, "shell.qml")
    if os.path.exists(shell_dst):
        os.remove(shell_dst)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), shell_dst)
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


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


def qs_ipc(qs_bin, shell_qml, env, *args, check=True):
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:reap", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    if check and out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    frame_log = os.path.join(work_dir, "frames.jsonl")
    open(frame_log, "w").close()

    mock_proc, ws_url = start_mock_daemon(
        os.path.join(test_dir, "mock-daemon.py"), work_dir, frame_log
    )

    # One remote executor, no defaultExecutor — defaultExecutorId resolves to
    # it, so both launchBackground sessions land on the mock daemon.
    executors_json = json.dumps([{"id": "remote", "url": ws_url, "token": TOKEN}])

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(work_dir)

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_EXECUTORS": executors_json,
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

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

    def dump_logs():
        for name in ("qs.log", "mock-daemon.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-4000:])
        sys.stderr.write("\n== frame log ==\n")
        try:
            sys.stderr.write(open(frame_log).read()[-4000:])
        except OSError as e:
            sys.stderr.write(f"(could not read frame log: {e})\n")

    def die(msg):
        dump_logs()
        fail(msg)

    def raw_sessions():
        return json.loads(qs_ipc(qs_bin, shell_qml, env, "rawSessions"))

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:reap" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:reap IPC target")

        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "executorConnected", "remote") == "true"
            ),
            timeout_s=30,
        ):
            die("panel never connected to the remote executor")

        def session_ids():
            return {s["id"] for s in raw_sessions()}

        # ── A: the held background launch (busy + pending forever) ──
        base = session_ids()
        qs_ipc(qs_bin, shell_qml, env, "launchBackground", "HOLD a long running task")
        a_new = wait_until(lambda: (session_ids() - base) or None, timeout_s=10)
        a_id = next(iter(a_new)) if a_new else None
        if not a_id:
            die("background launch A created no session")
        if not wait_until(
            lambda: qs_ipc(qs_bin, shell_qml, env, "sessionBusy", a_id) == "true",
            timeout_s=30,
        ):
            die("session A never became busy (held turn)")

        # ── B: a quick launch that runs to completion ──
        base2 = session_ids()
        qs_ipc(qs_bin, shell_qml, env, "launchBackground", "quick ping")
        b_new = wait_until(lambda: (session_ids() - base2) or None, timeout_s=10)
        b_id = next(iter(b_new)) if b_new else None
        if not b_id:
            die("background launch B created no session")
        # B finishes: agent_end clears busy, the reply streamed in.
        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "sessionBusy", b_id) == "false"
                and REPLY in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", b_id)
            ),
            timeout_s=60,
        ):
            die("session B never completed its turn")
        # B must still be attached (streaming) so the reaper has work to do.
        if qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", b_id) != "true":
            die("session B detached before reap — nothing to reap")

        # Both entries need their daemon ids minted before the frame-log
        # assertions can be keyed.
        def daemon_ids():
            m = {s["id"]: s["daemonSessionId"] for s in raw_sessions()}
            a, b = m.get(a_id, ""), m.get(b_id, "")
            return (a, b) if a and b else None

        ids = wait_until(daemon_ids, timeout_s=10)
        if not ids:
            die(f"daemon session ids never materialised: {raw_sessions()!r}")
        a_sid, b_sid = ids

        # No detach so far: nothing has been stopped yet.
        pre = detach_sids()
        if pre & {a_sid, b_sid}:
            die(f"unexpected detach frames before reap: {pre!r}")

        # ── the reaper runs ──
        qs_ipc(qs_bin, shell_qml, env, "reapIdle")

        # B (idle streaming) must be stopped: detach frame for its daemon id.
        if not wait_until(lambda: b_sid in detach_sids(), timeout_s=10):
            die(f"reaper sent no detach frame for the idle session B ({b_sid})")

        # A (busy + pending) must SURVIVE: no detach frame, still busy and
        # attached. Settle briefly so a late wrongful detach is counted.
        time.sleep(1.0)
        sids = detach_sids()
        if a_sid in sids:
            die(f"reaper detached the busy background launch A ({a_sid})")
        if qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", b_id) != "false":
            die("session B still reports streaming after reap — stop() didn't land")
        if qs_ipc(qs_bin, shell_qml, env, "sessionStreaming", a_id) != "true":
            die("session A is no longer streaming after reap — it should survive")
        if qs_ipc(qs_bin, shell_qml, env, "sessionBusy", a_id) != "true":
            die("session A is no longer busy after reap — it was disturbed")

        print("PASS")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()


if __name__ == "__main__":
    main()
