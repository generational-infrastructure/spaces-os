#!/usr/bin/env python3
"""Headless check: pi-chat.json `localExecutor` -> executors entry -> WS hello.

Runs the real PiChatBackend in a headless quickshell, pointed via the
$SPACES_PI_CHAT_CONFIG seam at a fixture config, and asserts:

  (a) a config carrying localExecutor {id:"host", url:"ws://127.0.0.1:<p>"}
      materializes a backend.executors entry with token "" and tokenPath
      $XDG_RUNTIME_DIR/pi-sessiond-local/token;
  (b) the executor authenticates against a fake pi-sessiond whose expected
      token is the token FILE's content (hello -> welcome), proving the
      tokenPath plumbing end-to-end;
  (c) regression: without localExecutor the executors list stays empty —
      the transient no-executor state (spawns defer until configured).

This is the cheap per-feature counterpart to the full test-machine VM
test (which boots the shipping self-hosted topology): no compositor, no
pi, no LLM, no VM. ~10s.

Usage: driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir> <fake_daemon>
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time

TOKEN = "local-exec-secret"
SENTINEL_MODEL = "local-exec-sentinel"


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
        try:
            if predicate():
                return True
        except Exception:
            pass
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
    """Stage the whole plugin tree (PiChatBackend pulls in PiExecutor /
    PiSession / qs.Commons / qs.Widgets) with our shell.qml on top, fresh
    mtimes for qmlcache."""
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
    return os.path.join(shell_root, "shell.qml")


class QsRun:
    """One headless quickshell instance with its own HOME + XDG_RUNTIME_DIR
    (per-run runtime dir keeps the IPC sockets of the two runs apart)."""

    def __init__(
        self, name: str, qs_bin: str, shell_qml: str, work_dir: str, config: dict
    ):
        self.name = name
        self.qs_bin = qs_bin
        self.shell_qml = shell_qml
        self.work_dir = work_dir
        self.home = os.path.join(work_dir, name, "home")
        self.xdg = os.path.join(work_dir, name, "xdg")
        os.makedirs(self.home, exist_ok=True)
        os.makedirs(self.xdg, exist_ok=True)
        os.chmod(self.xdg, 0o700)
        self.config_path = os.path.join(work_dir, name, "pi-chat.json")
        with open(self.config_path, "w") as fh:
            json.dump(config, fh)
        self.env = {
            "HOME": self.home,
            "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
            "XDG_RUNTIME_DIR": self.xdg,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
            "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
            "NIXPKGS_QT6_QML_IMPORT_PATH": os.environ.get(
                "NIXPKGS_QT6_QML_IMPORT_PATH", ""
            ),
            "SPACES_PI_CHAT_CONFIG": self.config_path,
        }
        self.log_path = os.path.join(work_dir, f"qs.{name}.log")
        self._log = open(self.log_path, "w")
        self.proc = subprocess.Popen(
            [qs_bin, "-p", shell_qml], env=self.env, stdout=self._log, stderr=self._log
        )

    def ipc(self, *args) -> str:
        r = subprocess.run(
            [self.qs_bin, "ipc", "-p", self.shell_qml, "call", "test:localexec", *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        if r.returncode != 0:
            raise RuntimeError(f"ipc {args} failed (exit={r.returncode}): {r.stderr!r}")
        return r.stdout.strip()

    def ipc_ready(self) -> bool:
        r = subprocess.run(
            [self.qs_bin, "ipc", "-p", self.shell_qml, "show"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and "test:localexec" in r.stdout

    def stop(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    qs_bin, test_dir, plugin_dir, work_dir, fake_daemon = sys.argv[1:6]
    os.makedirs(work_dir, exist_ok=True)
    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)

    port = free_port()
    ws_url = f"ws://127.0.0.1:{port}"

    daemon_log = open(os.path.join(work_dir, "daemon.log"), "w")
    daemon = subprocess.Popen(
        [sys.executable, fake_daemon, str(port), TOKEN],
        stdout=daemon_log,
        stderr=subprocess.STDOUT,
    )

    qs = None

    def dump(extra=()):
        for path in [os.path.join(work_dir, "daemon.log"), *extra]:
            if os.path.isfile(path):
                sys.stderr.write(
                    f"\n== {path} ==\n" + open(path, errors="replace").read()
                )

    def die(msg):
        dump([qs.log_path] if qs else [])
        fail(msg)

    try:
        # The executor connects once on startup, so the daemon must already
        # be listening (same race note as pi-session-ws).
        if not wait_for_port(port, timeout_s=15):
            dump()
            fail(f"fake daemon never listened on port {port} (exit={daemon.poll()})")

        # ── run 1: localExecutor configured ───────────────────────────────
        qs = QsRun(
            "with-local",
            qs_bin,
            shell_qml,
            work_dir,
            {
                "defaultModel": SENTINEL_MODEL,
                "localExecutor": {"id": "host", "url": ws_url},
            },
        )
        # Mint the per-login token where the daemon contract puts it:
        # $XDG_RUNTIME_DIR/pi-sessiond-local/token. Trailing newline checks
        # the panel trims the read. The daemon only answers `welcome` when
        # the hello token equals the file CONTENT, so a successful connect
        # proves the tokenPath plumbing end-to-end.
        token_dir = os.path.join(qs.xdg, "pi-sessiond-local")
        os.makedirs(token_dir, exist_ok=True)
        token_path = os.path.join(token_dir, "token")
        with open(token_path, "w") as fh:
            fh.write(TOKEN + "\n")
        os.chmod(token_path, 0o600)

        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell never bound the test:localexec IPC target")

        # (a) the executors entry materializes with the runtime token path.
        if not wait_until(lambda: json.loads(qs.ipc("executorsJson")), timeout_s=20):
            die(f"executors never materialized (executors={qs.ipc('executorsJson')!r})")
        executors = json.loads(qs.ipc("executorsJson"))
        if len(executors) != 1:
            die(f"expected exactly one executor, got {executors!r}")
        entry = executors[0]
        expected = {
            "id": "host",
            "url": ws_url,
            "token": "",
            "tokenPath": token_path,
        }
        for k, v in expected.items():
            if entry.get(k) != v:
                die(f"executor entry {k}={entry.get(k)!r}, want {v!r} ({entry!r})")

        # (b) hello with the token-file content reaches welcome.
        if not wait_until(
            lambda: qs.ipc("executorConnected", "host") == "true", timeout_s=20
        ):
            die("loopback executor never connected/authenticated (token from file)")

        qs.stop()

        # ── run 2 (regression): no localExecutor -> executors stays empty ──
        qs = QsRun(
            "without-local",
            qs_bin,
            shell_qml,
            work_dir,
            {"defaultModel": SENTINEL_MODEL},
        )
        if not wait_until(qs.ipc_ready, timeout_s=30):
            die("quickshell (regression run) never bound the IPC target")
        # Gate on the sentinel so the empty-list assertion can't pass before
        # the FileView actually loaded the fixture config.
        if not wait_until(lambda: qs.ipc("cfgModel") == SENTINEL_MODEL, timeout_s=20):
            die(f"fixture config never loaded (defaultModel={qs.ipc('cfgModel')!r})")
        executors = json.loads(qs.ipc("executorsJson"))
        if executors != []:
            die(f"executors must stay empty without localExecutor, got {executors!r}")

        sys.stderr.write(
            "PASS: localExecutor entry + token-file hello/welcome + empty-without-config\n"
        )
    finally:
        if qs:
            qs.stop()
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()


if __name__ == "__main__":
    main()
