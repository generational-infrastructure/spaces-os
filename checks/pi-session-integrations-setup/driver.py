#!/usr/bin/env python3
"""Headless check: the panel's integration device-setup flow.

Drives the real SettingsWindow + IntegrationsBridge against a Python fake
broker that streams the setup op's NDJSON events (qr | message | done | error |
text-field | secret-field). Asserts the UI contract the sandboxed setup channel
depends on:
  - the Link/Setup button shows ONLY for an integration that is BOTH enabled
    AND setup-capable (github: enabled/no-setup and mail: setup/disabled must
    NOT show it; signal and caldav must),
  - clicking it opens the inline pane and a qr event makes the QR Image
    visible with the streamed png data URL,
  - a done event flips to the success state, auto-closes the pane, and the
    bridge fires a re-list (observed via the broker's stats sidecar),
  - a text-field/secret-field prompt shows an input (masked for secret-field),
    and each submitted reply reaches the broker verbatim as a {"value":...}
    line (observed via the stats sidecar),
  - the error path surfaces the error text and keeps the pane open.

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
    stats_path = sock_path + ".stats"
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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:setup")
    qs.start()

    def die(msg):
        qs.die(msg, extra_logs=("broker.log",))

    def ipc(*args):
        return qs.ipc(*args)

    def stats() -> dict:
        try:
            return json.loads(open(stats_path).read())
        except (OSError, ValueError):
            return {}

    try:
        if not wait_until(qs.ipc_ready, timeout_s=20):
            die("quickshell never bound the test:setup IPC target")

        # The bridge auto-lists on startup; the delegates (and their setup
        # buttons) materialise once the list arrives.
        if not wait_until(
            lambda: ipc("exists", "setupBtn-signal") == "true", timeout_s=15
        ):
            die("integration delegates never built (setupBtn-signal missing)")

        # Visibility gate: shown ONLY when enabled AND setup-capable.
        if ipc("visibleOf", "setupBtn-signal") != "true":
            die("signal (enabled + setup-capable) should show the setup button")
        if ipc("visibleOf", "setupBtn-caldav") != "true":
            die("caldav (enabled + setup-capable) should show the setup button")
        if ipc("visibleOf", "setupBtn-github") != "false":
            die("github (enabled, NOT setup-capable) must not show the setup button")
        if ipc("visibleOf", "setupBtn-mail") != "false":
            die("mail (setup-capable but disabled) must not show the setup button")

        lists_before = stats().get("list", 0)

        # Launch signal setup: clicking the button starts the stream.
        if ipc("click", "setupBtn-signal") != "ok":
            die("could not click the signal setup button")

        # qr event -> the QR Image becomes visible carrying the streamed png.
        if not wait_until(lambda: ipc("setupPhase") == "qr", timeout_s=15):
            die(f"setup never reached the qr phase (phase={ipc('setupPhase')!r})")
        if not wait_until(lambda: ipc("visibleOf", "setupQr") == "true", timeout_s=10):
            die("QR image never became visible after the qr event")
        src = ipc("qrSource")
        if "data:image/png;base64," not in src or "iVBOR" not in src:
            die(f"QR image source is not the streamed png data URL: {src!r}")

        # done -> success state, then auto-close (setupFor clears), plus a
        # re-list fired by the bridge (visible in the broker stats).
        if not wait_until(lambda: ipc("setupFor") == "", timeout_s=15):
            die(
                f"setup flow never auto-closed after done (setupFor={ipc('setupFor')!r})"
            )
        if not wait_until(lambda: stats().get("list", 0) > lists_before, timeout_s=10):
            die(f"no re-list after done (before={lists_before}, stats={stats()!r})")

        # Prompt flow: proton streams a text-field then a secret-field. The
        # panel shows an input (masked for secret-field); each submitted reply
        # reaches the broker verbatim.
        if ipc("click", "setupBtn-proton") != "ok":
            die("could not click the proton setup button")
        if not wait_until(lambda: ipc("setupPhase") == "prompt", timeout_s=15):
            die(
                f"proton setup never reached the prompt phase (phase={ipc('setupPhase')!r})"
            )
        if ipc("visibleOf", "setupPromptInput") != "true":
            die("prompt input should be visible in the prompt phase")
        if ipc("echoModeOf", "setupPromptInput") != "normal":
            die("a text-field prompt must not be masked")
        if ipc("setText", "setupPromptInput", "user@proton.me") != "ok":
            die("could not type into the text-field prompt")
        if ipc("click", "setupSubmit") != "ok":
            die("could not submit the text-field reply")

        # The secret-field prompt: same input, now masked.
        if not wait_until(
            lambda: (
                ipc("setupPhase") == "prompt"
                and ipc("echoModeOf", "setupPromptInput") == "password"
            ),
            timeout_s=15,
        ):
            die("proton setup never reached the masked secret-field prompt")
        if ipc("setText", "setupPromptInput", "bridge-token") != "ok":
            die("could not type into the secret-field prompt")
        if ipc("click", "setupSubmit") != "ok":
            die("could not submit the secret-field reply")

        # done -> auto-close, and the broker received both replies verbatim.
        if not wait_until(lambda: ipc("setupFor") == "", timeout_s=15):
            die(
                f"proton prompt flow never auto-closed after done (setupFor={ipc('setupFor')!r})"
            )
        if not wait_until(
            lambda: stats().get("replies") == ["user@proton.me", "bridge-token"],
            timeout_s=10,
        ):
            die(
                f"broker did not receive both replies verbatim: {stats().get('replies')!r}"
            )

        # Error path: caldav's setup streams an error -> error text shown, and
        # the pane stays open (no auto-close).
        if ipc("click", "setupBtn-caldav") != "ok":
            die("could not click the caldav setup button")
        if not wait_until(lambda: ipc("setupPhase") == "error", timeout_s=15):
            die(
                f"caldav setup never reached the error phase (phase={ipc('setupPhase')!r})"
            )
        if not wait_until(
            lambda: "device link failed" in ipc("statusText"), timeout_s=10
        ):
            die(f"error text not surfaced in the setup pane: {ipc('statusText')!r}")
        if ipc("setupFor") != "caldav":
            die(f"error pane should stay open (setupFor={ipc('setupFor')!r})")

        sys.stderr.write(
            "PASS: setup-button gate + streamed QR visible + done auto-close + "
            "re-list + prompt replies + error text\n"
        )
    finally:
        qs.stop()
        reap(broker)


if __name__ == "__main__":
    main()
