#!/usr/bin/env python3
"""Headless check: the panel renders an integration tool-call approval and
replies the user's decision over the §12 WebSocket transport.

Runs the real PiExecutor + PiSession (WS mode) in a headless quickshell against
a fake gateway, then for each decision {once, session, deny} asserts:
  - a pending approval bubble appears carrying the gateway's tool + args,
  - after respond(), the bubble's state flips to that decision, and
  - the gateway actually received an approval_response{decision} on the wire
    (recorded to a file), proving the reply is sent — not merely patched local.

The cheap per-feature counterpart to the full VM test: no compositor, pi, LLM,
or VM. Usage: driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir>
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time

TOKEN = "approval-check-secret"
DECISIONS = [("appr-once", "once"), ("appr-session", "session"), ("appr-deny", "deny")]


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def wait_for_port(port: int, *, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    root = os.path.join(work_dir, "shell")
    os.makedirs(root, exist_ok=True)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), os.path.join(root, "shell.qml"))
    for f in ("PiExecutor.qml", "PiSession.qml"):
        shutil.copy2(os.path.join(plugin_dir, f), os.path.join(root, f))
    shutil.copytree(
        os.path.join(plugin_dir, "Commons"),
        os.path.join(root, "Commons"),
        dirs_exist_ok=True,
    )
    now = time.time()
    for r, _dirs, files in os.walk(root):
        for f in files:
            try:
                os.utime(os.path.join(r, f), (now, now))
            except OSError:
                pass
    return os.path.join(root, "shell.qml")


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    port = free_port()
    ws_url = f"ws://127.0.0.1:{port}"

    xdg = os.path.join(work_dir, "xdg")
    os.makedirs(xdg, exist_ok=True)
    os.chmod(xdg, 0o700)
    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)
    record = os.path.join(work_dir, "responses.ndjson")

    daemon_log = open(os.path.join(work_dir, "daemon.log"), "w")
    daemon = subprocess.Popen(
        [
            sys.executable,
            os.path.join(test_dir, "fake-daemon.py"),
            str(port),
            TOKEN,
            record,
        ],
        stdout=daemon_log,
        stderr=subprocess.STDOUT,
    )

    if not wait_for_port(port, timeout_s=15):
        sys.stderr.write(
            "\n== daemon.log ==\n" + open(os.path.join(work_dir, "daemon.log")).read()
        )
        fail(f"fake gateway never listened on port {port} (exit={daemon.poll()})")

    token_path = os.path.join(work_dir, "ws-token")
    with open(token_path, "w") as fh:
        fh.write(TOKEN + "\n")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "NIXPKGS_QT6_QML_IMPORT_PATH": os.environ.get(
            "NIXPKGS_QT6_QML_IMPORT_PATH", ""
        ),
        "PI_WS_URL": ws_url,
        "PI_WS_TOKEN": "",
        "PI_WS_TOKEN_PATH": token_path,
    }

    qs_out = open(os.path.join(work_dir, "qs.out.log"), "w")
    qs_err = open(os.path.join(work_dir, "qs.err.log"), "w")
    qs = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_out, stderr=qs_err
    )

    def dump():
        for name in ("qs.out.log", "qs.err.log", "daemon.log"):
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {name} ==\n" + open(path).read())

    def die(msg):
        dump()
        fail(msg)

    def ipc(*args):
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "call", "test:approval", *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if r.returncode != 0:
            raise RuntimeError(f"ipc {args} failed (exit={r.returncode}): {r.stderr!r}")
        return r.stdout.strip()

    def ipc_ready():
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "show"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and "test:approval" in r.stdout

    def recorded():
        if not os.path.isfile(record):
            return []
        out = []
        for line in open(record):
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    try:
        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:approval IPC target")
        if not wait_until(lambda: ipc("connected") == "true", timeout_s=15):
            die("panel never connected/authenticated over WS")

        for idx, (appr_id, decision) in enumerate(DECISIONS):
            ipc("send", f"approve:{appr_id}")
            if not wait_until(
                lambda aid=appr_id: ipc("approvalState", aid) == "pending", timeout_s=15
            ):
                die(f"approval bubble {appr_id} never appeared pending")

            # First one: the panel must surface exactly what the gateway sent.
            if idx == 0:
                tool = ipc("approvalTool", appr_id)
                if tool != "github_create_issue":
                    die(f"approval bubble tool mismatch: {tool!r}")
                args = ipc("approvalArgs", appr_id)
                if "octo/repo" not in args or "hello" not in args:
                    die(f"approval bubble did not surface the gateway args: {args!r}")

            # Pre-decision: nothing recorded for this id yet.
            if any(r.get("id") == appr_id for r in recorded()):
                die(f"approval_response for {appr_id} recorded before the user decided")

            ipc("respond", appr_id, decision)
            if not wait_until(
                lambda aid=appr_id, d=decision: ipc("approvalState", aid) == d,
                timeout_s=15,
            ):
                die(f"approval bubble {appr_id} state never became {decision!r}")
            if not wait_until(
                lambda aid=appr_id, d=decision: any(
                    r.get("id") == aid and r.get("decision") == d for r in recorded()
                ),
                timeout_s=15,
            ):
                die(
                    f"gateway never received approval_response {{{appr_id}: {decision}}} on the wire"
                )

        sys.stderr.write(
            "PASS: approval_request rendered + once/session/deny replied over WS\n"
        )
    finally:
        qs.terminate()
        try:
            qs.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs.kill()
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()


if __name__ == "__main__":
    main()
