#!/usr/bin/env python3
"""Contract test: PiSession.restart() re-asserts the selected model.

Pi's `new_session` command spawns a fresh agent loaded with the default
model from settings.json. If the user had switched to a different model
on the previous session, the QML dropdown keeps its stale label but pi
silently runs the next turn on the default. PiSession.restart() must
re-issue `set_model` after `new_session` so wire state matches the UI.

The test drives a headless quickshell instance with a hand-rolled
PiSession that points at a fake pi binary. The fake pi appends every
NDJSON frame it receives on stdin to a witness file. A stub
systemd-run wrapper strips its sandbox flags and execs the fake pi
directly so we don't need a real user manager inside the build sandbox.

Expected witness contents after setModel → restart, when modelPref is
non-empty:
  1. {"type":"set_model", ...}     ← initial selection
  2. {"type":"new_session"}        ← restart()
  3. {"type":"set_model", ...}     ← restart() re-asserts modelPref

Without the fix, frame 3 is missing and the test fails.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1) -> bool:
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
        os.path.join(test_dir, "shell.qml"),
        os.path.join(shell_root, "shell.qml"),
    )
    shutil.copytree(
        os.path.join(test_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    shutil.copy2(
        os.path.join(plugin_dir, "PiSession.qml"),
        os.path.join(shell_root, "PiSession.qml"),
    )
    return shell_root


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:restart-model", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def read_frames(witness_path: str) -> list[dict]:
    """Parse every JSON line in the witness (skip the STARTED marker)."""
    if not os.path.exists(witness_path):
        return []
    frames: list[dict] = []
    with open(witness_path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line == "STARTED":
                continue
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError:
                # Surface in the failure message instead of swallowing.
                frames.append({"__raw__": line})
    return frames


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    state_dir = os.path.join(work_dir, "state")
    agent_dir = os.path.join(state_dir, "pi-agent")
    workspace = os.path.join(work_dir, "workspace")
    os.makedirs(os.path.join(state_dir, "sessions", "test"), exist_ok=True)
    os.makedirs(agent_dir, exist_ok=True)
    os.makedirs(workspace, exist_ok=True)

    witness = os.path.join(work_dir, "frames.log")
    open(witness, "w").close()

    # Stage stubs into a dedicated bin/ that we'll put first on PATH.
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    systemd_run_dst = os.path.join(bin_dir, "systemd-run")
    shutil.copy2(os.path.join(test_dir, "fake-systemd-run"), systemd_run_dst)
    os.chmod(systemd_run_dst, 0o755)
    fake_pi_dst = os.path.join(bin_dir, "fake-pi")
    with (
        open(os.path.join(test_dir, "fake-pi.py")) as src,
        open(fake_pi_dst, "w") as dst,
    ):
        text = src.read()
        # Rewrite the shebang to the python interpreter the driver itself
        # runs under — `/usr/bin/env python3` is not guaranteed to resolve
        # inside the build sandbox.
        if text.startswith("#!"):
            text = "#!" + sys.executable + "\n" + text.split("\n", 1)[1]
        dst.write(text)
    os.chmod(fake_pi_dst, 0o755)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    suppress_file = os.path.join(work_dir, "suppress-new-session-response")
    env = os.environ.copy()
    env.update(
        {
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "TEST_PI_BIN": fake_pi_dst,
            "TEST_STATE_DIR": state_dir,
            "TEST_AGENT_DIR": agent_dir,
            "TEST_WORKSPACE": workspace,
            "FAKE_PI_WITNESS": witness,
            "FAKE_PI_SUPPRESS_FILE": suppress_file,
            "HOME": work_dir,
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def dump_logs() -> None:
        try:
            qs_log.flush()
            with open(os.path.join(work_dir, "qs.log")) as fh:
                sys.stderr.write("\n== qs.log ==\n")
                sys.stderr.write(fh.read())
            if os.path.exists(witness):
                sys.stderr.write("\n== witness ==\n")
                with open(witness) as fh:
                    sys.stderr.write(fh.read())
        except Exception:
            pass

    try:

        def ipc_ready() -> bool:
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:restart-model" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            dump_logs()
            fail("IPC never registered")

        # Bring the fake pi up.
        qs_ipc_call(qs_bin, shell_qml, env, "spawnSession")
        if not wait_until(
            lambda: (
                "STARTED" in (open(witness).read() if os.path.exists(witness) else "")
            ),
            timeout_s=10,
        ):
            dump_logs()
            fail("fake pi never started — witness has no STARTED marker")

        # Initial model selection.
        qs_ipc_call(qs_bin, shell_qml, env, "setModel", "local", "mock-model")
        if not wait_until(
            lambda: any(f.get("type") == "set_model" for f in read_frames(witness)),
            timeout_s=5,
        ):
            dump_logs()
            fail("initial set_model frame never arrived")

        # The contract under test.
        qs_ipc_call(qs_bin, shell_qml, env, "restart")

        # Expect: new_session, then a re-asserted set_model with the same
        # provider/modelId. Wait long enough for both writes to drain.
        def restart_complete() -> bool:
            frames = read_frames(witness)
            has_new_session = any(f.get("type") == "new_session" for f in frames)
            set_model_count = sum(1 for f in frames if f.get("type") == "set_model")
            return has_new_session and set_model_count >= 2

        if not wait_until(restart_complete, timeout_s=5):
            dump_logs()
            frames = read_frames(witness)
            fail(
                "restart() did not re-assert set_model after new_session.\n"
                f"frames: {json.dumps(frames, indent=2)}"
            )

        # Order check: the re-asserted set_model must come after new_session.
        frames = read_frames(witness)
        types = [f.get("type") for f in frames]
        try:
            ns_idx = types.index("new_session")
        except ValueError:
            dump_logs()
            fail(f"new_session missing from witness: {types}")
        post = [f for f in frames[ns_idx + 1 :] if f.get("type") == "set_model"]
        if not post:
            dump_logs()
            fail(f"no set_model frame after new_session: {types}")
        if post[0].get("provider") != "local" or post[0].get("modelId") != "mock-model":
            dump_logs()
            fail(f"re-asserted set_model has wrong payload: {post[0]!r}")

        # ── phase 2 ────────────────────────────────────────────────────
        # Without pi's ack, PiSession must NOT send set_model. Block the
        # fake pi from responding and verify no fresh set_model leaks
        # out within a generous timeout.
        open(suppress_file, "w").close()
        baseline_set_model = sum(
            1 for f in read_frames(witness) if f.get("type") == "set_model"
        )
        baseline_new_session = sum(
            1 for f in read_frames(witness) if f.get("type") == "new_session"
        )
        qs_ipc_call(qs_bin, shell_qml, env, "restart")
        # Wait for new_session to land first so we know the restart
        # actually fired (we're just blocking the *response*, not the
        # request).
        if not wait_until(
            lambda: (
                sum(1 for f in read_frames(witness) if f.get("type") == "new_session")
                > baseline_new_session
            ),
            timeout_s=5,
        ):
            dump_logs()
            fail("suppressed-response restart: new_session never sent")
        # Now give the race plenty of head-room. If PiSession were
        # firing set_model unconditionally (the broken behaviour), it
        # would land here.
        time.sleep(2.0)
        post_suppress_set_model = sum(
            1 for f in read_frames(witness) if f.get("type") == "set_model"
        )
        if post_suppress_set_model != baseline_set_model:
            dump_logs()
            frames = read_frames(witness)
            fail(
                "set_model leaked out without pi's new_session ack "
                f"(baseline={baseline_set_model}, after={post_suppress_set_model}).\n"
                f"frames: {json.dumps(frames, indent=2)}"
            )

        # ── phase 3 ────────────────────────────────────────────────────
        # Re-enable responses and restart again. The previously
        # withheld response is gone forever (pi would never replay it
        # in real life), so this exercises a fresh request that must
        # now succeed. Confirms phase 2's silence wasn't a permanent
        # broken state.
        os.unlink(suppress_file)
        qs_ipc_call(qs_bin, shell_qml, env, "restart")
        if not wait_until(
            lambda: (
                sum(1 for f in read_frames(witness) if f.get("type") == "set_model")
                > post_suppress_set_model
            ),
            timeout_s=5,
        ):
            dump_logs()
            frames = read_frames(witness)
            fail(
                "phase 3 restart did not re-assert set_model.\n"
                f"frames: {json.dumps(frames, indent=2)}"
            )

        print("PASS")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
