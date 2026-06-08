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
import shutil
import subprocess
import sys
import time

TOKEN = "dup-secret"


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


def start_mock_daemon(mock_script: str, work_dir: str):
    log = open(os.path.join(work_dir, "mock-daemon.log"), "w")
    proc = subprocess.Popen(
        [sys.executable, mock_script, "remote", TOKEN],
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
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:dup", *args]
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

    # Seed a pre-existing sessions.json — the returning-desktop scenario. Its
    # presence is what makes FileView.onLoaded fire so _loadFromAdapter runs and
    # arms lastImportTime; on a fresh profile (no file) the importer stays
    # disarmed (lastImportTime == 0) and the bug can't show. The seeded value
    # itself is immaterial: the empty-sessions bootstrap re-arms the cutoff to
    # "now" at load time, still ahead of every session this run creates.
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

    mock_proc, ws_url = start_mock_daemon(
        os.path.join(test_dir, "mock-daemon.py"), work_dir
    )

    # Inject ONE remote executor, no defaultExecutor — so defaultExecutorId
    # silently resolves to it, the exact "single remote executor" topology the
    # bug needs. Passed as JSON via $SPACES_PI_CHAT_EXECUTORS (the panel's
    # test seam) since /etc/spaces/pi-chat.json is root-owned + unwritable here.
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
        for name in ("qs.log", "mock-daemon.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-4000:])
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

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:dup" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:dup IPC target")

        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "executorConnected", "remote") == "true"
            ),
            timeout_s=30,
        ):
            die("panel never connected to the remote executor")

        # ── (1) robustness: a remote session driven with launchBackground's
        # spawn()-then-send() double-spawn must mint exactly ONE daemon session
        # and leave exactly ONE index entry. The second spawn racing the first's
        # in-flight create_session is what orphans a second daemon session that
        # re-imports as the dead duplicate. ─────────────────────────────────
        sid = qs_ipc(qs_bin, shell_qml, env, "newSessionOn", "RemoteDouble", "remote")
        if not sid:
            die("newSessionOn returned no id")
        qs_ipc(qs_bin, shell_qml, env, "spawnSend", sid, "hi")

        # Wait for the streamed reply: by the time it lands, both create acks
        # and the `sessions` broadcasts have been processed, so any orphan/dup
        # has already materialised.
        if not wait_until(
            lambda: (
                "Hello from the remote executor"
                in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", sid)
            ),
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
        qid = qs_ipc(qs_bin, shell_qml, env, "launchBackground", "quick task here")

        def quick_entries():
            out = [
                s
                for s in raw_sessions()
                if s["id"] not in before and s.get("name") == "quick task here"
            ]
            return out or None

        entries = wait_until(quick_entries, timeout_s=10)
        if not entries:
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
