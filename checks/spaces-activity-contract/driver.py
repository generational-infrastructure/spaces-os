#!/usr/bin/env python3
"""Spaces Agent Sessions — activity.json contract component test.

Drives the sessions-bar plugin's Main.qml FileView service the same way
pi-chat does: by writing the activity feed to
$HOME/.local/state/spaces/pi/activity.json and reading the parsed model
back over the quickshell ipc CLI.

The fixtures below are literal replicas of what the producer emits —
PiChatBackend._writeActivity in programs/pi-chat/PiChatBackend.qml:

    { version: 1,
      activeSessionId: "<id of the focused chat>",
      sessions: [ { id, name, state } ] }   state ∈ "working" | "waiting"

(Do not import from pi-chat here; the point of this check is to freeze
the schema on both sides, so producer drift fails this build.)

Asserted contract, matching Main.qml's current behavior:

  1. no file yet                     → blank ([], "")      (onLoadFailed)
  2. working+waiting mix + active id → rows + highlight verbatim
  3. empty sessions feed (all chats
     closed)                         → blanks the populated bar
  4. unknown extra fields            → tolerated (parse still applies)
  5. version bump (version: 2)       → tolerated; consumer never reads
                                       `version`, feed still applies
  6. torn/partial write (bad JSON)   → keep-previous (no blanking)
  7. `sessions` not an array         → [] but activeSessionId applies
  8. file removed                    → blank ([], "")      (onLoadFailed)

Headless quickshell, offscreen platform. No pi-chat, no compositor. ~3-10s.
"""

import json
import os
import shutil
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    # Main.qml is the unit under test; stage it next to shell.qml so the
    # `Main {}` component resolves from the same directory.
    shutil.copy2(
        os.path.join(plugin_dir, "Main.qml"), os.path.join(shell_root, "Main.qml")
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:activity", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)
    # The consumer resolves $HOME/.local/state/spaces/pi/activity.json;
    # pre-create the directory the way pi-chat's stateDir setup would.
    activity_dir = os.path.join(work_dir, ".local", "state", "spaces", "pi")
    os.makedirs(activity_dir, exist_ok=True)
    activity_file = os.path.join(activity_dir, "activity.json")

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def dump_logs():
        for label, name in [
            ("qs.stdout", "qs.stdout.log"),
            ("qs.stderr", "qs.stderr.log"),
        ]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    def die(msg):
        dump_logs()
        fail(msg)

    def read_active() -> str:
        return ipc_call(qs_bin, shell_qml, env, "active")

    def read_sessions() -> str:
        return ipc_call(qs_bin, shell_qml, env, "sessions")

    def write_feed(obj) -> None:
        # Truncate-in-place, mirroring FileView.writeAdapter's plain write
        # on the producer side.
        with open(activity_file, "w") as f:
            f.write(json.dumps(obj))

    def write_raw(text: str) -> None:
        with open(activity_file, "w") as f:
            f.write(text)

    def expect(sessions: str, active: str, label: str) -> None:
        if not wait_until(
            lambda: read_sessions() == sessions and read_active() == active,
            timeout_s=8,
        ):
            die(
                f"{label}: expected sessions={sessions!r} active={active!r}, "
                f"got sessions={read_sessions()!r} active={read_active()!r}"
            )

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:activity" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:activity IPC target")

        # (1) No feed yet (pi-chat not up) → the startup reload hits
        # onLoadFailed → blank bar.
        expect("", "", "step1 no-file")

        # (2) Two chats, one mid-turn, focus on the working one. Literal
        # producer output shape (see module docstring).
        write_feed(
            {
                "version": 1,
                "activeSessionId": "sess-a",
                "sessions": [
                    {"id": "sess-a", "name": "Chat A", "state": "working"},
                    {"id": "sess-b", "name": "Chat B", "state": "waiting"},
                ],
            }
        )
        expect(
            "sess-a|Chat A|working;sess-b|Chat B|waiting",
            "sess-a",
            "step2 working+waiting mix + active highlight",
        )

        # (3) Producer up, zero chats: the exact empty feed
        # _writeActivity emits on an empty sessionsList must blank the
        # populated bar. Ordered after step 2 on purpose — asserting
        # blank from an already-blank bar would pass even if the feed
        # were never applied.
        write_feed({"version": 1, "activeSessionId": "", "sessions": []})
        expect("", "", "step3 populated → empty feed blanks")

        # (4) A future producer adding fields must not break the bar:
        # unknown top-level and per-session keys are carried, the three
        # contract fields still project verbatim.
        write_feed(
            {
                "version": 1,
                "activeSessionId": "sess-b",
                "generatedAt": 1750000000000,
                "sessions": [
                    {
                        "id": "sess-a",
                        "name": "Chat A",
                        "state": "waiting",
                        "unread": 3,
                    },
                    {"id": "sess-b", "name": "Chat B", "state": "working"},
                ],
            }
        )
        expect(
            "sess-a|Chat A|waiting;sess-b|Chat B|working",
            "sess-b",
            "step4 unknown extra fields tolerated",
        )

        # (5) Version bump: Main.qml never reads `version`, so a v2 feed
        # with the same field shape still applies. (If the consumer ever
        # grows version gating, update this step alongside it.)
        write_feed(
            {
                "version": 2,
                "activeSessionId": "sess-a",
                "sessions": [
                    {"id": "sess-a", "name": "Chat A", "state": "working"}
                ],
            }
        )
        expect(
            "sess-a|Chat A|working",
            "sess-a",
            "step5 version bump ignored",
        )

        # (6) Torn read mid-rewrite: invalid JSON must keep the previous
        # values rather than blanking the bar (Main.qml's catch branch).
        write_raw('{"version": 1, "activeSessionId": "sess-a", "sess')
        time.sleep(1.0)
        s, a = read_sessions(), read_active()
        if s != "sess-a|Chat A|working" or a != "sess-a":
            die(
                "step6 torn-read keep-previous: expected unchanged model, "
                f"got sessions={s!r} active={a!r}"
            )

        # (7) `sessions` not an array → Array.isArray guard empties the
        # list, while activeSessionId still applies from the same parse.
        write_feed(
            {"version": 1, "activeSessionId": "sess-x", "sessions": {"oops": 1}}
        )
        expect("", "sess-x", "step7 non-array sessions guard")

        # (8) Feed removed (pi-chat gone) → onLoadFailed → blank bar.
        os.remove(activity_file)
        expect("", "", "step8 removed")

        sys.stderr.write("PASS: activity.json producer/consumer contract holds\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
