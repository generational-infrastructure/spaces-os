#!/usr/bin/env python3
"""Model-directive launch contract test.

Proves that backend.launchBackground(prompt, {model}) runs the turn on
the REQUESTED model, not the executor's default.

The session lives on a REAL pi-sessiond on loopback. Two layers carry
the directive over the WebSocket, and this check pins their net effect:

  - the panel's create_session carries model "provider/id" (modelPref is
    persisted on the entry before the first spawn), so the daemon mints
    the session on the launched model; and
  - the prompt is sent only from the awaited set_model continuation —
    the daemon echoes the request `id` on its set_model response, which
    is what makes PiSession.setModelAndWait resolvable over the WS at
    all. A rejected set_model (unknown model) must abort the launch
    instead of silently running on whatever the daemon fell back to.

Assertions:

  1. The mock LLM serves a multi-model list (discovered by the daemon at
     startup); the daemon's default is a model that is deliberately NOT
     the one we launch with.
  2. launchBackground("summarize logs", {model:"local/gemma4:e4b"}).
  3. Every logged /v1/chat/completions request must carry model
     "gemma4:e4b" — if the directive were dropped anywhere along
     create_session/set_model, the turn would run on the default model
     and the assertion fails.
  4. The session title and "Agent finished" notification summarize the
     PROMPT ("summarize logs"), and the session stays in the index.

Failure path: a model the daemon's registry doesn't know makes set_model
respond with an error (same echoed id); the launch must then NOT send
the prompt and must clear its reaper-exempt pending mark.

Reuses the pi-session-quick-launch harness (mock LLM + stub notify-send
recording completion notifications); the daemon's bash confinement
wrapper is a passthrough stub since no bash tool commands run here.

Usage: driver.py <daemon_bin> <qs_bin> <mock_llm> <systemd_run_stub>
                  <test_dir> <harness_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time

TOKEN = "model-directive-secret"

# The daemon's default at startup (SPACES_SESSIOND_DEFAULT_MODEL);
# deliberately != LAUNCH_MODEL so asserting on LAUNCH_MODEL proves the
# directive actually selected the model rather than coincidentally
# matching the default.
DEFAULT_MODEL = "llama-3.2"
LAUNCH_MODEL = "gemma4:e4b"
MODELS = [LAUNCH_MODEL, "gpt-oss", DEFAULT_MODEL]
PROMPT = "summarize logs"
# A model the daemon's registry rejects (not in MODELS): set_model fails,
# so the launch must abort without sending the prompt and without leaking
# a pending background session.
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


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for_port(port: int, *, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


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


def start_daemon(daemon_bin: str, stub: str, mock_url: str, port: int, work_dir: str):
    """Real pi-sessiond on a free loopback port, as executor id "host".

    It discovers MODELS from the mock LLM's /v1/models at startup (the
    port only opens after discovery) and defaults to DEFAULT_MODEL — the
    model the launch directive must override."""
    state_dir = os.path.join(work_dir, "daemon-state")
    creds_dir = os.path.join(work_dir, "creds")
    os.makedirs(state_dir, exist_ok=True)
    os.makedirs(creds_dir, exist_ok=True)
    with open(os.path.join(creds_dir, "token"), "w") as fh:
        fh.write(TOKEN + "\n")

    # pi settings template for the daemon's embedded pi; the default model
    # mirrors the daemon-level default. No discovery extension — the daemon
    # does its own llama-swap model discovery.
    settings_path = os.path.join(work_dir, "settings.json")
    with open(settings_path, "w") as fh:
        json.dump(
            {
                "defaultProvider": "local",
                "defaultModel": DEFAULT_MODEL,
                "quietStartup": True,
                "enableInstallTelemetry": False,
            },
            fh,
        )

    env = os.environ.copy()
    env.update(
        {
            "SPACES_SESSIOND_HOST": "127.0.0.1",
            "SPACES_SESSIOND_PORT": str(port),
            "SPACES_SESSIOND_EXECUTOR_ID": "host",
            "CREDENTIALS_DIRECTORY": creds_dir,
            "LLAMA_SWAP_BASE_URL": mock_url,
            "SPACES_SESSIOND_DEFAULT_MODEL": DEFAULT_MODEL,
            "SPACES_SESSIOND_PI_SETTINGS": settings_path,
            "SPACES_SESSIOND_SYSTEMD_RUN": stub,
            "STATE_DIRECTORY": state_dir,
            # Idle-GC off so the launched/aborted sessions survive untouched
            # until every assertion has read them.
            "SPACES_SESSIOND_IDLE_TIMEOUT_MS": "0",
        }
    )
    log = open(os.path.join(work_dir, "daemon.log"), "wb")
    return subprocess.Popen([daemon_bin], env=env, stdout=log, stderr=subprocess.STDOUT)


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


def stage_bin(harness_dir: str, work_dir: str) -> str:
    """PATH overlay for quickshell: just the harness's notify-send witness
    (sessions run daemon-side; the panel only execs notify-send)."""
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    dst = os.path.join(bin_dir, "notify-send")
    shutil.copy2(os.path.join(harness_dir, "notify-send"), dst)
    os.chmod(dst, 0o755)
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
            "usage: driver.py <daemon_bin> <qs_bin> <mock_llm> "
            "<systemd_run_stub> <test_dir> <harness_dir> <plugin_dir> <work_dir>"
        )
    (
        daemon_bin,
        qs_bin,
        mock_script,
        stub,
        test_dir,
        harness_dir,
        plugin_dir,
        work_dir,
    ) = sys.argv[1:9]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_bin(harness_dir, work_dir)
    notify_witness = os.path.join(work_dir, "notify.log")
    request_log = os.path.join(work_dir, "mock-requests.log")

    mock_proc, mock_url = start_mock_llm(mock_script, work_dir)

    port = free_port()
    daemon_proc = start_daemon(daemon_bin, stub, mock_url, port, work_dir)
    if not wait_for_port(port, timeout_s=60):
        fail(f"pi-sessiond never listened on port {port} (exit={daemon_proc.poll()})")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "PATH": bin_dir + os.pathsep + env.get("PATH", ""),
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "NOTIFY_WITNESS": notify_witness,
            # Executor topology seam: the lone "host" executor — the real
            # daemon above — which defaultExecutorId resolves to.
            "SPACES_PI_CHAT_EXECUTORS": json.dumps(
                [{"id": "host", "url": f"ws://127.0.0.1:{port}", "token": TOKEN}]
            ),
        }
    )

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def dump_logs():
        for name in ("qs.log", "mock-llm.log", "daemon.log"):
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

        if not wait_until(
            lambda: (
                qs_ipc(qs_bin, shell_qml, env, "executorConnected", "host") == "true"
            ),
            timeout_s=30,
        ):
            die("panel never connected/authenticated to the host executor")

        if qs_ipc(qs_bin, shell_qml, env, "panelVisible") != "false":
            die("panel reported visible; the test requires it hidden")

        # Failure path first: a model the daemon doesn't know must NOT
        # silently launch on the default and must not leak a reaper-exempt
        # pending session. The daemon answers the panel's id-tagged
        # set_model with an error response, rejecting the awaited
        # _request, so the .then(send) never runs.
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

        # The prompt must stream back (proves the turn ran AND that the
        # daemon's pi logged its chat request — the model assertion reads
        # that log).
        if not wait_until(
            lambda: (
                "Background task complete"
                in qs_ipc(qs_bin, shell_qml, env, "lastAssistantText", sid)
            ),
            timeout_s=60,
        ):
            die("background session never received the streamed mock reply")

        # (a) THE DIRECTIVE GUARD. The prompt is sent only from the awaited
        # set_model continuation (resolved by the daemon's id-echoing
        # response), and create_session already carried the launched model
        # — so the chat request is causally after the daemon applied it. A
        # dropped or ignored directive runs the turn on DEFAULT_MODEL, and
        # a request carrying it fails this. No sleep: the streamed reply
        # waited on above guarantees the request is already logged, so
        # reading it now is deterministic.
        reqs = wait_until(lambda: chat_requests(request_log) or None, timeout_s=10)
        if not reqs:
            die("mock LLM logged no chat-completions request")
        used = [r.get("model") for r in reqs]
        if any(m != LAUNCH_MODEL for m in used):
            die(
                f"chat request ran on {used!r}, expected all {LAUNCH_MODEL!r} "
                f"(directive dropped or ignored; default is {DEFAULT_MODEL!r})"
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
        daemon_proc.terminate()
        try:
            daemon_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_proc.kill()
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()


if __name__ == "__main__":
    main()
