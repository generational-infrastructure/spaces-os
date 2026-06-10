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
import shutil
import subprocess
import sys
import time

DAY = 86400000
T0 = 1_700_000_000_000
INHERITED = "local/mock-model"
TOKEN = "inherits-secret"


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
    """Mirror the whole pi-chat tree, then drop in our test shell.qml."""
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


def qs_ipc(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:new-chat-model", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
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

    # Seed the backend's state dir: a sessions.json baseline so
    # FileView.onLoaded fires (arming the importer cutoff), plus the
    # frecency store. old-favourite has a far higher score but
    # mock-model has the later lastUsed. A score-based pick would
    # choose old-favourite, since 50 decayed over one 3-day half-life
    # is still ~39 > 1.
    state_dir = os.path.join(home, ".local", "state", "spaces", "pi")
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

    def dump_logs() -> None:
        for name in ("qs.log", "mock-daemon.log", "frames.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-6000:])
        sessions_json = os.path.join(state_dir, "sessions.json")
        if os.path.exists(sessions_json):
            sys.stderr.write("\n== sessions.json ==\n")
            sys.stderr.write(open(sessions_json).read())

    def die(msg: str) -> None:
        dump_logs()
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

        def ipc_ready() -> bool:
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:new-chat-model" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:new-chat-model IPC target")

        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "executorConnected", "remote") == "true"
            ),
            timeout_s=30,
        ):
            die("panel never connected to the mock executor")

        # ModelFrecency's startup FileView load is async. Wait for the
        # seeded store to land before newSession() consults it.
        if not wait_until(
            lambda: int(qs_ipc(qs_bin, shell_qml, env, "frecencyLoadGen")) >= 1,
            timeout_s=10,
        ):
            die("ModelFrecency startup FileView load never completed")

        # (1) Remote-import seam. Entries minted via _freshSessionEntry
        # (the _importRemoteSessions shape) keep model "".
        fresh = qs_ipc(qs_bin, shell_qml, env, "freshEntryModel")
        if fresh != "<empty>":
            die(f"_freshSessionEntry inherited a model: {fresh!r} (must stay '')")

        # (2) newSession() inherits the most recently selected model and
        # persists it on the index entry.
        sid = qs_ipc(qs_bin, shell_qml, env, "newSession", "inherit-test")
        if not sid:
            die("newSession returned no id")
        entry = wait_until(lambda: persisted_entry(sid), timeout_s=10)
        if not entry:
            die(f"session {sid!r} never appeared in sessions.json")
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
        qs_ipc(qs_bin, shell_qml, env, "sendTo", sid, "first prompt")
        create = wait_until(
            lambda: next(
                (
                    f
                    for f in recv_frames(frames_log)
                    if f.get("kind") == "create_session"
                ),
                None,
            ),
            timeout_s=15,
        )
        if not create:
            die("no create_session ever reached the mock daemon")
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

        prompt = wait_until(prompt_frame, timeout_s=15)
        if not prompt:
            die(
                "prompt never reached the daemon after the create: "
                f"{json.dumps(recv_frames(frames_log), indent=2)}"
            )
        kinds = [f.get("kind") for f in recv_frames(frames_log)]
        if kinds.index("create_session") > kinds.index("command"):
            die(f"prompt went out before create_session: {kinds}")

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
