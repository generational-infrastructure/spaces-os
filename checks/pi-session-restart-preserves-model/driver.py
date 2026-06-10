#!/usr/bin/env python3
"""Contract test: PiSession.restart() preserves the selected model.

PiSession is WS-only: every panel entry is backed by a pi-sessiond
session on an executor. restart() drops the daemon session backing the
entry and mints a new one on the same executor — delete + create, not an
in-place rebind. The selected model survives because the fresh
create_session envelope itself carries model="<provider>/<id>" equal to
the session's modelPref (no set_model replay after the fact).

Drives the real PiChatBackend (headless quickshell) against a mock
pi-sessiond that logs every frame in order. Sequence:

  1. newSession with a model pref seeded on the entry (entry.model is
     what the reconciler binds to PiSession.modelPref), spawn → the mock
     acks create_session #1 with a fresh daemon id D1.
  2. setModelAndWait round-trip: set_model goes out as a `command`
     envelope carrying a request id; the mock echoes it on its
     {type:"response", command:"set_model", ...} so the promise resolves.
  3. restart() → assert from the mock's frame log, in order:
       detach D1, delete_session D1, then a SECOND create_session whose
       model field is the expected "provider/id";
     and that the panel's index entry now carries the SECOND daemon id
     (the one the mock acked for create #2).

The remote executor topology is injected as JSON via
$SPACES_PI_CHAT_EXECUTORS (the panel's test seam) since the root-owned
/etc/spaces/pi-chat.json can't be written in the build sandbox. No real
pi/LLM/VM. ~10-20s.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

TOKEN = "restart-secret"
MODEL_PROVIDER = "mock"
MODEL_ID = "test-model"
MODEL_PREF = f"{MODEL_PROVIDER}/{MODEL_ID}"


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


def start_mock_daemon(mock_script: str, frames_log: str, work_dir: str):
    log = open(os.path.join(work_dir, "mock-daemon.log"), "w")
    proc = subprocess.Popen(
        [sys.executable, mock_script, frames_log, "remote", TOKEN],
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


def qs_ipc(qs_bin, shell_qml, env, *args, check=True):
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:restart", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    if check and out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


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

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # Seed sessions.json so FileView.onLoaded fires and _loadFromAdapter
    # runs (arming the importer cutoff) — the returning-desktop baseline
    # the sibling checks use.
    state_dir = os.path.join(home, ".local", "state", "spaces", "pi")
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

    frames_log = os.path.join(work_dir, "frames.log")
    open(frames_log, "w").close()
    mock_proc, ws_url = start_mock_daemon(
        os.path.join(test_dir, "mock-daemon.py"), frames_log, work_dir
    )

    executors_json = json.dumps([{"id": "remote", "url": ws_url, "token": TOKEN}])

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "SPACES_PI_CHAT_EXECUTORS": executors_json,
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def dump_logs():
        for name in ("qs.log", "mock-daemon.log", "frames.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-6000:])
        try:
            sys.stderr.write("\n== final index ==\n")
            sys.stderr.write(json.dumps(raw_sessions(), indent=2) + "\n")
        except Exception as e:
            sys.stderr.write(f"(could not read index: {e})\n")

    def die(msg):
        dump_logs()
        fail(msg)

    def raw_sessions():
        return json.loads(qs_ipc(qs_bin, shell_qml, env, "rawSessions"))

    def entry(sid):
        return next((s for s in raw_sessions() if s["id"] == sid), None)

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:restart" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:restart IPC target")

        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "executorConnected", "remote") == "true"
            ),
            timeout_s=30,
        ):
            die("panel never connected to the remote executor")

        # ── spawn: create_session #1 binds the entry to D1 ──────────────
        sid = qs_ipc(
            qs_bin,
            shell_qml,
            env,
            "newSessionWithModel",
            "RestartModel",
            "remote",
            MODEL_PREF,
        )
        if not sid:
            die("newSessionWithModel returned no id")
        qs_ipc(qs_bin, shell_qml, env, "spawnSession", sid)

        e = wait_until(
            lambda: (lambda x: x if x and x["daemonSessionId"] else None)(entry(sid)),
            timeout_s=30,
        )
        if not e:
            die("session never attached — entry has no daemonSessionId")
        d1 = e["daemonSessionId"]

        creates = [
            f for f in recv_frames(frames_log) if f.get("kind") == "create_session"
        ]
        if len(creates) != 1:
            die(f"expected exactly ONE create_session before restart, got {creates!r}")
        if creates[0].get("model") != MODEL_PREF:
            die(
                f"create_session #1 did not carry the seeded model pref: "
                f"expected {MODEL_PREF!r}, got {creates[0]!r}"
            )

        # ── set_model command round-trip (request id echoed by the mock) ─
        qs_ipc(qs_bin, shell_qml, env, "setModelWait", sid, MODEL_PROVIDER, MODEL_ID)
        result = wait_until(
            lambda: qs_ipc(qs_bin, shell_qml, env, "setModelResult"),
            timeout_s=10,
        )
        if not result:
            die("setModelAndWait never resolved — mock did not echo the request id")
        if result.startswith("ERROR"):
            die(f"setModelAndWait rejected: {result}")
        data = json.loads(result)
        if data.get("provider") != MODEL_PROVIDER or data.get("id") != MODEL_ID:
            die(f"set_model response carried wrong payload: {data!r}")

        # ── the contract under test ──────────────────────────────────────
        qs_ipc(qs_bin, shell_qml, env, "restartSession", sid)

        def restart_frames_complete():
            frames = recv_frames(frames_log)
            has_delete = any(
                f.get("kind") == "delete_session" and f.get("sessionId") == d1
                for f in frames
            )
            n_creates = sum(1 for f in frames if f.get("kind") == "create_session")
            return has_delete and n_creates >= 2

        if not wait_until(restart_frames_complete, timeout_s=15):
            die(
                "restart() never produced delete_session(D1) + a second "
                "create_session on the wire"
            )

        frames = recv_frames(frames_log)
        kinds = [(f.get("kind"), f.get("sessionId")) for f in frames]

        def index_of(pred, what):
            for i, f in enumerate(frames):
                if pred(f):
                    return i
            die(f"{what} missing from frame log: {kinds!r}")

        detach_idx = index_of(
            lambda f: f.get("kind") == "detach" and f.get("sessionId") == d1,
            f"detach for {d1}",
        )
        delete_idx = index_of(
            lambda f: f.get("kind") == "delete_session" and f.get("sessionId") == d1,
            f"delete_session for {d1}",
        )
        create_idxs = [
            i for i, f in enumerate(frames) if f.get("kind") == "create_session"
        ]
        if len(create_idxs) != 2:
            die(
                f"expected exactly TWO create_session frames, got {len(create_idxs)}: {kinds!r}"
            )
        second_create_idx = create_idxs[1]

        if not (detach_idx < delete_idx < second_create_idx):
            die(
                "restart frames out of order: expected detach(D1) < "
                f"delete_session(D1) < create_session#2, got detach={detach_idx} "
                f"delete={delete_idx} create2={second_create_idx}: {kinds!r}"
            )
        second_create = frames[second_create_idx]
        if second_create.get("model") != MODEL_PREF:
            die(
                "restart's fresh create_session must carry model=modelPref: "
                f"expected {MODEL_PREF!r}, got {second_create!r}"
            )

        # ── the entry rebinds to the SECOND daemon id ────────────────────
        e2 = wait_until(
            lambda: (
                lambda x: (
                    x
                    if x and x["daemonSessionId"] and x["daemonSessionId"] != d1
                    else None
                )
            )(entry(sid)),
            timeout_s=15,
        )
        if not e2:
            die(
                "index entry never rebound to a fresh daemon session id "
                f"(still {entry(sid)!r}, old id {d1!r})"
            )
        d2 = e2["daemonSessionId"]

        # Cross-check D2 against the id the mock actually acked for create #2:
        # the first `attached` the mock SENT after the second create_session.
        records = read_frames(frames_log)
        recv_seen = 0
        acked_d2 = None
        past_second_create = False
        for r in records:
            if r.get("dir") == "recv" and r["frame"].get("kind") == "create_session":
                recv_seen += 1
                past_second_create = recv_seen >= 2
            elif (
                past_second_create
                and r.get("dir") == "send"
                and r["frame"].get("kind") == "attached"
            ):
                acked_d2 = r["frame"].get("sessionId")
                break
        if acked_d2 != d2:
            die(
                f"entry daemonSessionId {d2!r} does not match the id the mock "
                f"acked for create_session #2 ({acked_d2!r})"
            )

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
