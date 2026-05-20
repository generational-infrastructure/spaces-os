#!/usr/bin/env python3
"""End-to-end skill-config prompt test.

Verifies the full request-input → prompt bubble → submit round-trip:

  1. Start the skill-config-daemon.
  2. Boot quickshell (offscreen) with the test shell that subscribes
     to the daemon socket and pushes prompt bubbles into PiSession.
  3. Act as a CLI: connect to the daemon, send a Request, get Registered.
  4. Assert a `type:"prompt"` bubble with `promptState:"pending"` appears
     in the session's messages (via qs ipc).
  5. Submit a value through the daemon.
  6. Assert the CLI receives `op:"submitted"` with the value.
  7. Assert the bubble state changes to `"submitted"` in the session.

No pi process, no LLM, no compositor. ~5s.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    """Copy shell.qml + PiSession.qml + Commons/ into work_dir/shell."""
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
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
    # Touch all files so Qt qmlcache sees fresh mtimes.
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def stage_systemd_run_stub(test_dir: str, work_dir: str) -> str:
    """Install systemd-run stub into work_dir/bin."""
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    dst = os.path.join(bin_dir, "systemd-run")
    # PiSession._buildCommand() calls systemd-run; we need a stub
    # that just execs the trailing command after --.
    with open(dst, "w") as f:
        f.write("#!/usr/bin/env bash\n")
        f.write('while [[ "$1" != "--" ]] && [[ $# -gt 0 ]]; do shift; done\n')
        f.write("shift  # skip the --\n")
        f.write('exec "$@"\n')
    os.chmod(dst, 0o755)
    return bin_dir


# ── daemon socket protocol helpers ────────────────────────────────

def daemon_connect(sock_path: str, timeout: float = 5.0) -> socket.socket:
    """Connect to the daemon, retrying briefly."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(sock_path)
            return s
        except (ConnectionRefusedError, FileNotFoundError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)


def daemon_send_recv(sock_path: str, payload: dict) -> dict:
    """One-shot: connect, send JSON line, read one JSON line, close."""
    s = daemon_connect(sock_path)
    try:
        f = s.makefile("rwb")
        f.write((json.dumps(payload) + "\n").encode())
        f.flush()
        line = f.readline()
        return json.loads(line) if line else {}
    finally:
        s.close()


def cli_request(sock_path: str, skill: str, profile: str, field: str,
                description: str, secret: bool = False,
                timeout_secs: int = 30) -> tuple[socket.socket, str]:
    """Simulate `skill-config request-input`.

    Returns (socket, request_id). Caller keeps the socket open and
    reads the terminal reply after the test submits/cancels.
    """
    s = daemon_connect(sock_path)
    f = s.makefile("rwb")
    req = {
        "op": "request",
        "skill": skill,
        "profile": profile,
        "field": field,
        "description": description,
        "secret": secret,
        "timeout_secs": timeout_secs,
    }
    f.write((json.dumps(req) + "\n").encode())
    f.flush()
    registered = json.loads(f.readline())
    if registered.get("op") != "registered":
        fail(f"expected 'registered', got {registered}")
    return s, registered["request_id"]


def cli_read_reply(sock: socket.socket) -> dict:
    """Read the terminal reply from an open CLI connection."""
    f = sock.makefile("rb")
    line = f.readline()
    sock.close()
    return json.loads(line) if line else {}


# ── quickshell IPC ────────────────────────────────────────────────

def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:skill", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


# ── main ──────────────────────────────────────────────────────────

def main():
    daemon_bin, qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:6]

    # Directories.
    state_dir = os.path.join(work_dir, "state")
    agent_dir = os.path.join(state_dir, "pi-agent")
    sessions_dir = os.path.join(state_dir, "sessions", "test")
    workspace = os.path.join(work_dir, "workspace")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    sock_path = os.path.join(xdg_runtime, "distro-skill-config.sock")
    for d in [state_dir, agent_dir, sessions_dir, workspace, xdg_runtime]:
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # Write minimal pi settings so PiSession doesn't choke.
    with open(os.path.join(agent_dir, "settings.json"), "w") as f:
        json.dump({"extensions": [], "skills": []}, f)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_systemd_run_stub(test_dir, work_dir)

    env = {
        "HOME": work_dir,
        "PATH": bin_dir + ":" + os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "TEST_STATE_DIR": state_dir,
        "TEST_AGENT_DIR": agent_dir,
        "TEST_WORKSPACE": workspace,
        "TEST_SKILL_SOCK": sock_path,
    }

    # 1. Start skill-config-daemon.
    daemon_env = dict(env)
    daemon_env["SKILL_CONFIG_SOCKET"] = sock_path
    daemon_proc = subprocess.Popen(
        [daemon_bin],
        env=daemon_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    # Wait for socket to appear.
    if not wait_until(lambda: os.path.exists(sock_path), timeout_s=5):
        daemon_proc.kill()
        fail("skill-config-daemon never created socket")

    # 2. Start quickshell.
    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def cleanup():
        qs_proc.terminate()
        daemon_proc.terminate()
        qs_proc.wait(timeout=5)
        daemon_proc.wait(timeout=5)

        def dump(label, path):
            if os.path.isfile(path):
                try:
                    sys.stderr.write(f"\n== {label} ==\n")
                    sys.stderr.write(open(path).read())
                except Exception:
                    pass

        dump("qs.stdout.log", os.path.join(work_dir, "qs.stdout.log"))
        dump("qs.stderr.log", os.path.join(work_dir, "qs.stderr.log"))

        # Dump daemon output.
        daemon_proc.stdout.close() if daemon_proc.stdout else None

        # Dump qslog if present.
        qs_rt = os.path.join(xdg_runtime, "quickshell")
        if os.path.isdir(qs_rt):
            for dirpath, _dirnames, filenames in os.walk(qs_rt):
                for fn in filenames:
                    fpath = os.path.join(dirpath, fn)
                    try:
                        data = open(fpath, errors="replace").read()
                        sys.stderr.write(f"\n== {fpath} ==\n{data}\n")
                    except Exception:
                        sys.stderr.write(f"\n== {fpath} ==\n<unreadable>\n")

    try:
        # Wait for IPC handler to register.
        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode != 0:
                sys.stderr.write(f"[ipc_ready] exit={r.returncode} stderr={r.stderr!r}\n")
                return False
            return "test:skill" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup()
            fail("quickshell never bound the test:skill IPC target")

        # Give the subscriber socket a moment to connect to the daemon.
        time.sleep(0.5)

        # 3. Simulate a CLI request-input.
        cli_sock, request_id = cli_request(
            sock_path,
            skill="calendar",
            profile="default",
            field="caldav_url",
            description="CalDAV server URL",
            secret=False,
        )

        # 4. Poll for the prompt bubble.
        def has_prompt_bubble():
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            try:
                msgs = json.loads(raw)
            except Exception:
                return False
            return any(
                m.get("type") == "prompt"
                and m.get("promptState") == "pending"
                and m.get("promptField") == "caldav_url"
                and m.get("promptSkill") == "calendar"
                and m.get("id") == request_id
                for m in msgs
            )

        if not wait_until(has_prompt_bubble, timeout_s=10):
            cli_sock.close()
            cleanup()
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            fail(
                f"expected a prompt bubble with field='caldav_url' and "
                f"promptState='pending', got messages={raw}"
            )

        # 5. Submit a value through the IPC handler.
        qs_ipc_call(qs_bin, shell_qml, env, "submit", request_id, "https://cloud.example.com/dav")

        # 6. Verify the CLI receives the submitted value.
        reply = cli_read_reply(cli_sock)
        if reply.get("op") != "submitted":
            cleanup()
            fail(f"expected CLI to receive op='submitted', got {reply}")
        if reply.get("value") != "https://cloud.example.com/dav":
            cleanup()
            fail(f"expected value='https://cloud.example.com/dav', got {reply.get('value')!r}")

        # 7. Verify the bubble state changed.
        def bubble_submitted():
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            try:
                msgs = json.loads(raw)
            except Exception:
                return False
            return any(
                m.get("id") == request_id
                and m.get("promptState") == "submitted"
                for m in msgs
            )

        if not wait_until(bubble_submitted, timeout_s=5):
            cleanup()
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            fail(f"prompt bubble never transitioned to 'submitted', messages={raw}")

        print("OK")
    finally:
        cleanup()


if __name__ == "__main__":
    main()
