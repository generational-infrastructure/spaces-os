#!/usr/bin/env python3
"""New-chat model inheritance contract test.

A new chat session created without an explicit model must default to
the model the user most recently selected, the max-lastUsed key in
the persisted frecency store. That inherited model must then be
applied to the fresh local pi worker before the first prompt goes
out.

The frecency store is seeded so "local/old-favourite" has a far
higher score but "local/mock-model" has the later lastUsed.
Inheritance must follow recency, not score. Phases:

  1. The remote-import seam. _freshSessionEntry() keeps model "" so
     auto-imported daemon sessions do not inherit a local pick.
  2. newSession() persists entry.model == "local/mock-model".
  3. Race gate. With the fake pi's set_model response suppressed, the
     prompt must not reach pi. pi dispatches stdin lines as
     fire-and-forget async tasks, so an ungated prompt can run on the
     default model.
  4. Happy path. set_model, then its ack, then the prompt, in witness
     order, on a fresh session with responses enabled.
  5. Graceful degradation. pi rejects set_model for a stale or
     unknown model. The prompt must still arrive. An implicit default
     must never block the turn, unlike the explicit /model: directive.

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


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1):
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


def stage_bin(test_dir: str, work_dir: str) -> str:
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    systemd_run_dst = os.path.join(bin_dir, "systemd-run")
    shutil.copy2(os.path.join(test_dir, "fake-systemd-run"), systemd_run_dst)
    os.chmod(systemd_run_dst, 0o755)
    # The backend's /etc/spaces/pi-chat.json is unreadable in the
    # build sandbox, so piBin falls back to the default "pi", resolved
    # via PATH inside the stub systemd-run. Stage the fake under that
    # name. The shebang is rewritten to the driver's interpreter
    # because /usr/bin/env python3 is not guaranteed to resolve inside
    # the sandbox.
    pi_dst = os.path.join(bin_dir, "pi")
    with (
        open(os.path.join(test_dir, "fake-pi.py")) as src,
        open(pi_dst, "w") as dst,
    ):
        text = src.read()
        if text.startswith("#!"):
            text = "#!" + sys.executable + "\n" + text.split("\n", 1)[1]
        dst.write(text)
    os.chmod(pi_dst, 0o755)
    return bin_dir


def qs_ipc(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:new-chat-model", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def read_witness(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    out: list[dict] = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                out.append({"__raw__": line})
    return out


def frames_for(path: str, sid: str) -> list[dict]:
    return [w for w in read_witness(path) if w.get("sid") == sid]


def first_index(frames: list[dict], direction: str, ftype: str) -> int:
    for i, w in enumerate(frames):
        if w.get("dir") == direction and w.get("frame", {}).get("type") == ftype:
            return i
    return -1


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(home, exist_ok=True)
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # Pre-create the backend's state dir. FileView.writeAdapter does
    # not create parents, and sessions.json must land for the
    # persistence assertion.
    state_dir = os.path.join(home, ".local", "state", "spaces", "pi")
    os.makedirs(os.path.join(state_dir, "sessions"), exist_ok=True)

    # Seed the frecency store. old-favourite has a far higher score
    # but mock-model has the later lastUsed. A score-based pick would
    # choose old-favourite, since 50 decayed over one 3-day half-life
    # is still ~39 > 1.
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

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(test_dir, work_dir)

    witness = os.path.join(work_dir, "frames.log")
    open(witness, "w").close()
    suppress_file = os.path.join(work_dir, "suppress-set-model-response")
    reject_file = os.path.join(work_dir, "reject-set-model")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "FAKE_PI_WITNESS": witness,
            "FAKE_PI_SUPPRESS_FILE": suppress_file,
            "FAKE_PI_REJECT_FILE": reject_file,
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
                sys.stderr.write(fh.read()[-8000:])
            if os.path.exists(witness):
                sys.stderr.write("\n== witness ==\n")
                with open(witness) as fh:
                    sys.stderr.write(fh.read())
            sessions_json = os.path.join(state_dir, "sessions.json")
            if os.path.exists(sessions_json):
                sys.stderr.write("\n== sessions.json ==\n")
                with open(sessions_json) as fh:
                    sys.stderr.write(fh.read())
        except Exception:
            pass

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
        sid1 = qs_ipc(qs_bin, shell_qml, env, "newSession", "phase-suppress")
        if not sid1:
            die("newSession returned no id")
        entry = wait_until(lambda: persisted_entry(sid1), timeout_s=10)
        if not entry:
            die(f"session {sid1!r} never appeared in sessions.json")
        if entry.get("model") != INHERITED:
            die(
                f"new session inherited {entry.get('model')!r}, expected "
                f"{INHERITED!r} (most recent pick; old-favourite has the "
                f"higher score but the older lastUsed)"
            )

        # (3) Race gate. Suppress the fake pi's set_model response. The
        # first prompt must not go out until pi acks the model switch.
        open(suppress_file, "w").close()
        qs_ipc(qs_bin, shell_qml, env, "sendTo", sid1, "first prompt")
        if not wait_until(
            lambda: first_index(frames_for(witness, sid1), "in", "set_model") >= 0,
            timeout_s=10,
        ):
            die(
                "fresh local session sent no set_model for the inherited "
                f"model: {json.dumps(frames_for(witness, sid1), indent=2)}"
            )
        sm = next(
            w["frame"]
            for w in frames_for(witness, sid1)
            if w["dir"] == "in" and w["frame"]["type"] == "set_model"
        )
        if sm.get("provider") != "local" or sm.get("modelId") != "mock-model":
            die(f"inherited set_model has wrong payload: {sm!r}")
        # Give a racy implementation generous head-room to leak the prompt.
        time.sleep(2.0)
        if first_index(frames_for(witness, sid1), "in", "prompt") >= 0:
            die(
                "prompt reached pi before the set_model ack "
                "(fire-and-forget race; the turn would run on the default "
                f"model): {json.dumps(frames_for(witness, sid1), indent=2)}"
            )

        # (4) Happy path on a fresh session. set_model, then its ack,
        # then the prompt.
        os.unlink(suppress_file)
        sid2 = qs_ipc(qs_bin, shell_qml, env, "newSession", "phase-clean")
        qs_ipc(qs_bin, shell_qml, env, "sendTo", sid2, "second prompt")
        if not wait_until(
            lambda: first_index(frames_for(witness, sid2), "in", "prompt") >= 0,
            timeout_s=10,
        ):
            die(
                "prompt never reached pi after the set_model ack: "
                f"{json.dumps(frames_for(witness, sid2), indent=2)}"
            )
        f2 = frames_for(witness, sid2)
        i_set = first_index(f2, "in", "set_model")
        i_ack = first_index(f2, "out", "response")
        i_prompt = first_index(f2, "in", "prompt")
        if not (0 <= i_set < i_ack < i_prompt):
            die(
                f"expected set_model({i_set}) < ack({i_ack}) < "
                f"prompt({i_prompt}): {json.dumps(f2, indent=2)}"
            )

        # (5) Graceful degradation. pi rejects the inherited model
        # (stale entry, disabled provider). The prompt must still go
        # out so the turn runs on pi's default instead of blocking.
        open(reject_file, "w").close()
        sid3 = qs_ipc(qs_bin, shell_qml, env, "newSession", "phase-reject")
        qs_ipc(qs_bin, shell_qml, env, "sendTo", sid3, "third prompt")
        if not wait_until(
            lambda: first_index(frames_for(witness, sid3), "in", "prompt") >= 0,
            timeout_s=10,
        ):
            die(
                "rejected set_model blocked the prompt (implicit "
                "inheritance must degrade to the default model): "
                f"{json.dumps(frames_for(witness, sid3), indent=2)}"
            )
        f3 = frames_for(witness, sid3)
        i_rej = next(
            (
                i
                for i, w in enumerate(f3)
                if w["dir"] == "out"
                and w["frame"]["type"] == "response"
                and not w["frame"]["success"]
            ),
            -1,
        )
        i_prompt3 = first_index(f3, "in", "prompt")
        if not (0 <= i_rej < i_prompt3):
            die(
                f"expected set_model rejection({i_rej}) before the "
                f"prompt({i_prompt3}): {json.dumps(f3, indent=2)}"
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
