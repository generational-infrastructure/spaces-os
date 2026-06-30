#!/usr/bin/env python3
"""Headless check: the panel's IntegrationsBridge speaks the spaces-integrationd
socket protocol.

Drives the real IntegrationsBridge QML component against a Python fake broker
(request/reply-per-connection, in-memory state), asserting the full provisioning
state machine the settings form depends on:
  - list populates `integrations` (github, disabled, token unset),
  - enable is refused while a secret is unset (error surfaced, stays disabled),
  - set-secret flips the secret's `set` marker,
  - enable then succeeds (enabled flips true, error clears),
  - disable flips it back.

No pi, no LLM, no compositor. Usage:
  driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir>
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
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    root = os.path.join(work_dir, "shell")
    os.makedirs(root, exist_ok=True)
    shutil.copy2(os.path.join(test_dir, "shell.qml"), os.path.join(root, "shell.qml"))
    shutil.copy2(
        os.path.join(plugin_dir, "IntegrationsBridge.qml"),
        os.path.join(root, "IntegrationsBridge.qml"),
    )
    now = time.time()
    for r, _dirs, files in os.walk(root):
        for f in files:
            try:
                os.utime(os.path.join(r, f), (now, now))
            except OSError:
                pass
    return os.path.join(root, "shell.qml")


def main() -> None:
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    xdg = os.path.join(work_dir, "xdg")
    os.makedirs(xdg, exist_ok=True)
    os.chmod(xdg, 0o700)
    sock_path = os.path.join(xdg, "spaces-integrations.sock")
    shell_qml = stage_shell(test_dir, plugin_dir, work_dir)

    broker_log = open(os.path.join(work_dir, "broker.log"), "w")
    broker = subprocess.Popen(
        [sys.executable, os.path.join(test_dir, "fake_broker.py"), sock_path],
        stdout=broker_log,
        stderr=subprocess.STDOUT,
    )

    if not wait_until(lambda: os.path.exists(sock_path), timeout_s=10):
        fail(f"fake broker never bound {sock_path} (exit={broker.poll()})")

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
        "TEST_INTEGRATIONS_SOCK": sock_path,
    }

    qs_out = open(os.path.join(work_dir, "qs.out.log"), "w")
    qs_err = open(os.path.join(work_dir, "qs.err.log"), "w")
    qs = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_out, stderr=qs_err
    )

    def dump():
        for name in ("qs.out.log", "qs.err.log", "broker.log"):
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {name} ==\n" + open(path).read())

    def die(msg):
        dump()
        fail(msg)

    def ipc(*args):
        r = subprocess.run(
            [qs_bin, "ipc", "-p", shell_qml, "call", "test:integrations", *args],
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
        return r.returncode == 0 and "test:integrations" in r.stdout

    def integrations():
        return json.loads(ipc("integrationsJson"))

    def github():
        for it in integrations():
            if it.get("name") == "github":
                return it
        return None

    def token_set():
        gh = github()
        if not gh:
            return None
        for s in gh.get("secrets", []):
            if s.get("name") == "token":
                return s.get("set")
        return None

    try:
        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:integrations IPC target")

        # list → github present, disabled, token unset.
        ipc("refresh")
        if not wait_until(lambda: ipc("loaded") == "true", timeout_s=15):
            die("bridge never loaded the broker's integration list")
        gh = github()
        if not gh:
            die(f"github integration missing from list: {integrations()!r}")
        if gh.get("enabled") is not False:
            die(f"github should start disabled: {gh!r}")
        if token_set() is not False:
            die(f"token should start unset: {gh!r}")

        # enable refused while the secret is unset — error surfaced, stays off.
        ipc("enable", "github")
        if not wait_until(lambda: "missing secrets" in ipc("lastError"), timeout_s=15):
            die(
                f"enable without a secret should be refused (lastError={ipc('lastError')!r})"
            )
        if github().get("enabled") is True:
            die("github became enabled despite the unset secret")

        # set-secret flips the marker.
        ipc("setSecret", "github", "token", "ghp_example")
        if not wait_until(lambda: token_set() is True, timeout_s=15):
            die(f"token never marked set after set-secret: {github()!r}")

        # enable now succeeds; error clears.
        ipc("enable", "github")
        if not wait_until(lambda: github().get("enabled") is True, timeout_s=15):
            die(f"github never enabled after the secret was set: {github()!r}")
        if not wait_until(lambda: ipc("lastError") == "", timeout_s=10):
            die(
                f"lastError not cleared after a successful enable: {ipc('lastError')!r}"
            )

        # disable flips it back.
        ipc("disable", "github")
        if not wait_until(lambda: github().get("enabled") is False, timeout_s=15):
            die(f"github never disabled: {github()!r}")

        sys.stderr.write("PASS: list + enable-guard + set-secret + enable + disable\n")
    finally:
        qs.terminate()
        try:
            qs.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs.kill()
        broker.terminate()
        try:
            broker.wait(timeout=5)
        except subprocess.TimeoutExpired:
            broker.kill()


if __name__ == "__main__":
    main()
