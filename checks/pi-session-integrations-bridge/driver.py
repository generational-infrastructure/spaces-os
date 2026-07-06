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
import sys

from qs_harness import Quickshell, fail, qs_env, reap, spawn, stage_shell, wait_for_path
from qs_harness import wait_until as _wait_until


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1) -> bool:
    return _wait_until(predicate, timeout_s=timeout_s, interval_s=interval_s)


def main() -> None:
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    sock_path = os.path.join(work_dir, "xdg", "spaces-integrations.sock")
    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir, extra={"TEST_INTEGRATIONS_SOCK": sock_path})

    broker = spawn(
        [sys.executable, os.path.join(test_dir, "fake_broker.py"), sock_path],
        work_dir,
        "broker.log",
    )

    if not wait_for_path(sock_path, timeout_s=10):
        fail(f"fake broker never bound {sock_path} (exit={broker.poll()})")

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:integrations")
    qs.start()

    def die(msg):
        qs.die(msg, extra_logs=("broker.log",))

    def ipc(*args):
        return qs.ipc(*args)

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
        if not wait_until(qs.ipc_ready, timeout_s=20):
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
        if not wait_until(
            lambda: "no complete profile" in ipc("lastError"), timeout_s=15
        ):
            die(
                f"enable with no profile should be refused (lastError={ipc('lastError')!r})"
            )
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
        if not wait_until(
            lambda: profile("work") and profile("work").get("complete") is True,
            timeout_s=15,
        ):
            die(f"profile never completed after the secret was set: {mail()!r}")
        if profile("work").get("secrets", {}).get("password") is not True:
            die(f"secret set-marker not flipped: {profile('work')!r}")

        # enable now succeeds; error clears.
        ipc("enable", "mail")
        if not wait_until(lambda: mail().get("enabled") is True, timeout_s=15):
            die(f"mail never enabled after a complete profile: {mail()!r}")
        if not wait_until(lambda: ipc("lastError") == "", timeout_s=10):
            die(
                f"lastError not cleared after a successful enable: {ipc('lastError')!r}"
            )

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
        qs.stop()
        reap(broker)


if __name__ == "__main__":
    main()
