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

    def mail():
        for it in integrations():
            if it.get("name") == "mail":
                return it
        return None

    def profile(name):
        for p in (mail() or {}).get("profiles", []):
            if p.get("name") == name:
                return p
        return None

    try:
        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:integrations IPC target")

        # list → mail present, multi-profile, disabled, no profiles yet.
        ipc("refresh")
        if not wait_until(lambda: ipc("loaded") == "true", timeout_s=15):
            die("bridge never loaded the broker's integration list")
        m = mail()
        if not m:
            die(f"mail integration missing from list: {integrations()!r}")
        if m.get("multiProfile") is not True:
            die(f"mail should be multiProfile: {m!r}")
        if m.get("enabled") is not False or m.get("profiles"):
            die(f"mail should start disabled with no profiles: {m!r}")

        # enable refused with no complete profile — error surfaced, stays off.
        ipc("enable", "mail")
        if not wait_until(lambda: "no complete profile" in ipc("lastError"), timeout_s=15):
            die(f"enable with no profile should be refused (lastError={ipc('lastError')!r})")
        if mail().get("enabled") is True:
            die("mail became enabled despite no complete profile")

        # set a config field → the profile appears but is not yet complete.
        ipc("setField", "mail", "work", "imap_host", "imap.example.com")
        if not wait_until(lambda: profile("work") is not None, timeout_s=15):
            die(f"profile 'work' never appeared after set-field: {mail()!r}")
        if profile("work").get("config", {}).get("imap_host") != "imap.example.com":
            die(f"config value not reflected: {profile('work')!r}")
        if profile("work").get("complete") is True:
            die("profile complete before the required secret was set")

        # set the required secret → profile becomes complete (value never echoed).
        ipc("setField", "mail", "work", "password", "hunter2")
        if not wait_until(lambda: profile("work") and profile("work").get("complete") is True, timeout_s=15):
            die(f"profile never completed after the secret was set: {mail()!r}")
        if profile("work").get("secrets", {}).get("password") is not True:
            die(f"secret set-marker not flipped: {profile('work')!r}")

        # enable now succeeds; error clears.
        ipc("enable", "mail")
        if not wait_until(lambda: mail().get("enabled") is True, timeout_s=15):
            die(f"mail never enabled after a complete profile: {mail()!r}")
        if not wait_until(lambda: ipc("lastError") == "", timeout_s=10):
            die(f"lastError not cleared after a successful enable: {ipc('lastError')!r}")

        # disable flips it back.
        ipc("disable", "mail")
        if not wait_until(lambda: mail().get("enabled") is False, timeout_s=15):
            die(f"mail never disabled: {mail()!r}")

        # remove-profile drops the account.
        ipc("removeProfile", "mail", "work")
        if not wait_until(lambda: profile("work") is None, timeout_s=15):
            die(f"profile 'work' never removed: {mail()!r}")

        sys.stderr.write(
            "PASS: list + enable-guard + set-field(config,secret) + complete + enable + disable + remove-profile\n"
        )
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
