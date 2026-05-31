#!/usr/bin/env python3
"""Model-directive launch contract test.

Proves that backend.launchBackground(prompt, {model}) applies the
requested model to the pi worker BEFORE the prompt turn runs — the
race the awaited set_model fix closes.

pi dispatches stdin RPC lines as fire-and-forget async tasks, so a
fire-and-forget `set_model` followed immediately by the prompt can race:
the turn starts on the *default* model. The backend must await pi's
set_model response before sending the prompt. This check pins that:

  1. The mock LLM serves a multi-model list; pi's default is a model
     that is deliberately NOT the one we launch with.
  2. launchBackground("summarize logs", {model:"local/gemma4:e4b"}).
  3. The logged /v1/chat/completions request must carry model
     "gemma4:e4b" — if set_model raced (or was ignored), pi would have
     run the turn on the default model and the assertion fails.
  4. The session title and "Agent finished" notification summarize the
     PROMPT ("summarize logs"), and the session stays in the index.

Reuses the pi-session-quick-launch harness: a stub `systemd-run` execs
pi directly (no user systemd manager in the build sandbox) and a stub
`notify-send` records completion notifications.

Usage: driver.py <pi_bin> <qs_bin> <mock_llm> <ext_dir> <test_dir>
                  <stubs_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time

# pi's default at startup; deliberately != LAUNCH_MODEL so asserting on
# LAUNCH_MODEL proves set_model actually changed the active model rather
# than coincidentally matching the default.
DEFAULT_MODEL = "llama-3.2"
LAUNCH_MODEL = "gemma4:e4b"
MODELS = [LAUNCH_MODEL, "gpt-oss", DEFAULT_MODEL]
PROMPT = "summarize logs"
# A model pi will reject (not in MODELS): set_model fails, so the launch
# must abort without sending the prompt and without leaking a pending
# background session.
BAD_PROMPT = "diagnose the outage"
BAD_MODEL = "local/does-not-exist"


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


def start_mock_llm(mock_script: str, work_dir: str):
    log = open(os.path.join(work_dir, "mock-llm.log"), "w")
    env = os.environ.copy()
    env["MOCK_REQUEST_LOG"] = os.path.join(work_dir, "mock-requests.log")
    env["MOCK_MODELS_JSON"] = json.dumps(MODELS)
    proc = subprocess.Popen(
        [sys.executable, mock_script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log,
        env=env,
    )
    line = proc.stdout.readline()
    if not line:
        fail("mock LLM did not print its URL")
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


def stage_bin(stubs_dir: str, pi_bin: str, work_dir: str) -> str:
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    for name in ("fake-systemd-run", "notify-send"):
        dst = os.path.join(
            bin_dir, "systemd-run" if name == "fake-systemd-run" else name
        )
        shutil.copy2(os.path.join(stubs_dir, name), dst)
        os.chmod(dst, 0o755)
    pi_link = os.path.join(bin_dir, "pi")
    if os.path.exists(pi_link):
        os.remove(pi_link)
    os.symlink(pi_bin, pi_link)
    return bin_dir


def qs_ipc(
    qs_bin: str, shell_qml: str, env: dict, *args: str, check: bool = True
) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:quick-launch", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
    if check and out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def read_ndjson(path: str) -> list:
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def chat_requests(request_log: str) -> list:
    return [
        r for r in read_ndjson(request_log) if isinstance(r, dict) and r.get("messages")
    ]


def request_mentions(request_log: str, needle: str) -> bool:
    return any(
        needle in json.dumps(r.get("messages", "")) for r in chat_requests(request_log)
    )


def agent_finished_notifications(witness: str) -> list:
    return [
        a for a in read_ndjson(witness) if isinstance(a, list) and "Agent finished" in a
    ]


def main() -> None:
    if len(sys.argv) != 9:
        fail(
            "usage: driver.py <pi_bin> <qs_bin> <mock_llm> <ext_dir> "
            "<test_dir> <stubs_dir> <plugin_dir> <work_dir>"
        )
    (
        pi_bin,
        qs_bin,
        mock_script,
        ext_dir,
        test_dir,
        stubs_dir,
        plugin_dir,
        work_dir,
    ) = sys.argv[1:9]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    agent_dir = os.path.join(work_dir, "agent")
    for d in (home, xdg_runtime, agent_dir):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # pi agent config: local provider + the llama-swap discovery
    # extension (so pi resolves the multi-model list against the mock).
    # defaultModel is a discovered model so pi starts on it deterministically
    # — and it is NOT LAUNCH_MODEL, so the request-model assertion is sharp.
    with open(os.path.join(agent_dir, "settings.json"), "w") as fh:
        json.dump(
            {
                "extensions": [os.path.join(ext_dir, "llama-swap-discover.ts")],
                "defaultProvider": "local",
                "defaultModel": DEFAULT_MODEL,
                "quietStartup": True,
                "enableInstallTelemetry": False,
            },
            fh,
        )

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(stubs_dir, pi_bin, work_dir)
    notify_witness = os.path.join(work_dir, "notify.log")
    request_log = os.path.join(work_dir, "mock-requests.log")

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "PI_CODING_AGENT_DIR": agent_dir,
            "LLAMA_SWAP_BASE_URL": mock_url,
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
            "NOTIFY_WITNESS": notify_witness,
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def dump_logs():
        for name in ("qs.log", "mock-llm.log"):
            p = os.path.join(work_dir, name)
            if os.path.isfile(p):
                sys.stderr.write(f"\n== {name} ==\n")
                sys.stderr.write(open(p, errors="replace").read()[-6000:])
        for label, p in (
            ("notify witness", notify_witness),
            ("request log", request_log),
        ):
            if os.path.exists(p):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(p).read())

    def die(msg):
        dump_logs()
        fail(msg)

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:quick-launch" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:quick-launch IPC target")

        if qs_ipc(qs_bin, shell_qml, env, "panelVisible") != "false":
            die("panel reported visible; the test requires it hidden")

        # Failure path first: an unknown model must NOT silently launch on
        # the default (plan §4a) and must not leak a reaper-exempt pending
        # session. set_model rejects, so the awaited .then(send) never runs.
        bad_id = qs_ipc(
            qs_bin, shell_qml, env, "launchBackground", BAD_PROMPT, BAD_MODEL
        )
        if not bad_id:
            die("failed-model launchBackground returned no session id")
        # The rejection is async; once the pending mark clears we know the
        # .catch ran — which is the only branch that clears it without a
        # completed turn, so the prompt was provably never sent.
        if not wait_until(
            lambda: qs_ipc(qs_bin, shell_qml, env, "isPending", bad_id) == "false",
            timeout_s=20,
        ):
            die("failed-model session stayed pending (reaper-exempt leak)")
        if request_mentions(request_log, BAD_PROMPT):
            die("failed-model launch sent the prompt anyway (ran on default model)")

        sessions_before = json.loads(qs_ipc(qs_bin, shell_qml, env, "listSessions"))
        ids_before = {s["id"] for s in sessions_before}

        model_arg = "local/" + LAUNCH_MODEL
        # check=False: tolerate launchBackground ignoring the model opts in
        # the RED state — we still reach the observable model assertion.
        new_id = qs_ipc(
            qs_bin, shell_qml, env, "launchBackground", PROMPT, model_arg, check=False
        )

        def new_session_id():
            sessions = json.loads(qs_ipc(qs_bin, shell_qml, env, "listSessions"))
            extra = [s for s in sessions if s["id"] not in ids_before]
            return extra[0] if extra else None

        sess = wait_until(new_session_id, timeout_s=10)
        if not sess:
            die("launchBackground did not create a new session in the index")
        sid = sess["id"]
        if new_id and new_id != sid:
            sys.stderr.write(
                f"note: launchBackground returned {new_id!r}, index shows {sid!r}\n"
            )

        # The prompt must stream back (proves the turn ran AND that pi
        # logged its chat request — the model assertion reads that log).
        if not wait_until(
            lambda: (
                "Background task complete"
                in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", sid)
            ),
            timeout_s=60,
        ):
            die("background session never received the streamed mock reply")

        # (a) THE RACE GUARD. The prompt is sent only from the awaited
        # .then(set_model) continuation, so the chat request is causally
        # after pi applied the model — not merely "eventually". A racy or
        # ignored set_model runs the turn on DEFAULT_MODEL, and a request
        # carrying it fails this. No sleep: the streamed reply waited on
        # above guarantees the request is already logged, so reading it now
        # is deterministic.
        reqs = wait_until(lambda: chat_requests(request_log) or None, timeout_s=10)
        if not reqs:
            die("mock LLM logged no chat-completions request")
        used = [r.get("model") for r in reqs]
        if any(m != LAUNCH_MODEL for m in used):
            die(
                f"chat request ran on {used!r}, expected all {LAUNCH_MODEL!r} "
                f"(set_model raced or was ignored; default is {DEFAULT_MODEL!r})"
            )

        # (b) title + notification summarize the PROMPT (directive stripped).
        if sess.get("name") != PROMPT:
            die(f"session title {sess.get('name')!r} != prompt summary {PROMPT!r}")
        if not wait_until(
            lambda: len(agent_finished_notifications(notify_witness)) >= 1,
            timeout_s=30,
        ):
            die("no 'Agent finished' notification fired on completion")
        time.sleep(1.0)
        notifs = agent_finished_notifications(notify_witness)
        if len(notifs) != 1:
            die(
                f"expected exactly one 'Agent finished' notification, got {len(notifs)}: {notifs!r}"
            )
        body = notifs[0][-1]
        if body != PROMPT:
            die(f"notification body {body!r} != prompt summary {PROMPT!r}")

        # (c) the session is selectable from the index.
        qs_ipc(qs_bin, shell_qml, env, "selectSession", sid)
        if qs_ipc(qs_bin, shell_qml, env, "activeSessionId") != sid:
            die("background session is not selectable from the index")

        # (d) the backend model cache dedups on provider/id — the
        # /v1/models cache and a live session's models collide on the same
        # id and must not double-list. A bare id takes the default provider.
        merged = json.loads(qs_ipc(qs_bin, shell_qml, env, "mergeModelsProbe"))
        keys = sorted(f"{m['provider']}/{m['id']}" for m in merged)
        if keys != [f"local/{LAUNCH_MODEL}", "local/gpt-oss"]:
            die(f"model cache dedup wrong: {keys!r}")

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
