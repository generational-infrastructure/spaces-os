#!/usr/bin/env python3
"""Headless check: the panel's Nix-managed integration-profiles rendering.

Drives the real SettingsWindow + IntegrationsBridge against a Python fake
broker whose `list` reply carries the managed-profile contract fields (design
doc §10.5): ProfileInfo.managed / .shadowed and IntegrationInfo.enabledByNix.
Asserts the read-only GUI contract (§10.7):

  1. a managed profile renders a lock badge + STATIC config value rows (the
     values themselves, not editable inputs);
  2. that managed profile's edit/remove affordances are ABSENT from the tree
     (a distinct read-only delegate — not disabled inputs), while a sibling
     USER profile keeps its editable inputs + remove button (contrast);
  3. an enabledByNix integration shows a static enable label INSTEAD of the
     enable/disable toggle (toggle absent), while an integration with no Nix
     verdict keeps its toggle (contrast);
  4. the add-account input stays available on the multiProfile integration
     (and is absent on a single-account one);
  5. starting an add-profile draft with a managed profile's name is blocked
     (draftError shows, the draft editor is not instantiated), while a free
     name opens the draft editor (contrast — the block is name-specific).

Finally a raw-socket probe verifies the broker's managed-write rejections
(§10.5) come back with the exact, stable contract messages, and that writes to
UNmanaged targets still succeed.

No pi, no LLM, no compositor. Usage:
  driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import socket
import sys

from qs_harness import Quickshell, fail, qs_env, reap, spawn, stage_shell, wait_for_path
from qs_harness import wait_until as _wait_until


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.1) -> bool:
    return _wait_until(predicate, timeout_s=timeout_s, interval_s=interval_s)


def probe(sock_path: str, req: dict) -> dict:
    """Send one request to the fake broker on a fresh connection (the broker's
    one-request-per-connection convention); return the parsed reply, {} on EOF."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    try:
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.decode()) if buf.strip() else {}
    finally:
        s.close()


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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:managed")
    qs.start()

    def die(msg):
        qs.die(msg, extra_logs=("broker.log",))

    def ipc(*args):
        return qs.ipc(*args)

    def exists(name):
        return ipc("exists", name) == "true"

    def visible(name):
        return ipc("visibleOf", name) == "true"

    try:
        if not wait_until(qs.ipc_ready, timeout_s=20):
            die("quickshell never bound the test:managed IPC target")

        # The bridge auto-lists on startup; the managed delegate materialises
        # once the list arrives. lockBadge existing is the readiness sentinel.
        if not wait_until(lambda: exists("lockBadge-mail-work"), timeout_s=15):
            die("managed profile delegate never built (lockBadge-mail-work missing)")

        # ── (1) managed profile: lock badge + STATIC config rows ───────────
        if not visible("lockBadge-mail-work"):
            die("managed profile 'work' should show its lock badge")
        for field, val in (
            ("address", "bob@corp.example"),
            ("imap_host", "imap.corp.example"),
        ):
            row = f"cfgRow-mail-work-{field}"
            if not visible(row):
                die(f"managed profile 'work' should render a static row {row}")
            if val not in ipc("textOf", row):
                die(
                    f"static row {row} should show the managed value {val!r} "
                    f"(got {ipc('textOf', row)!r})"
                )
        if not visible("secretBadge-mail-work-password"):
            die("managed profile 'work' should show a static 'set' secret badge")

        # The shadowed managed profile carries BOTH the lock and shadow badges;
        # the non-shadowed one must not show a shadow badge.
        if not visible("lockBadge-mail-personal"):
            die("managed profile 'personal' should show its lock badge")
        if not visible("shadowBadge-mail-personal"):
            die("shadowed managed profile 'personal' should show its shadow badge")
        if "bob@home.example" not in ipc("textOf", "cfgRow-mail-personal-address"):
            die("static row for 'personal' should show its managed address value")
        if visible("shadowBadge-mail-work"):
            die("non-shadowed managed profile 'work' must NOT show a shadow badge")

        # ── (2) managed edit/remove affordances ABSENT from the tree ───────
        for name in (
            "cfgInput-mail-work-address",
            "cfgInput-mail-work-imap_host",
            "secInput-mail-work-password",
            "profileRemove-mail-work",
            "cfgInput-mail-personal-address",
            "profileRemove-mail-personal",
        ):
            if exists(name):
                die(
                    f"managed profile affordance {name} must be ABSENT from the tree "
                    "(not merely disabled)"
                )
        # Contrast: the sibling USER profile 'side' keeps its editable inputs +
        # remove button, and renders NO static row (proves a distinct delegate,
        # not a global removal of affordances).
        for name in (
            "cfgInput-mail-side-address",
            "cfgInput-mail-side-imap_host",
            "secInput-mail-side-password",
            "profileRemove-mail-side",
        ):
            if not exists(name):
                die(f"user profile affordance {name} should be present (contrast)")
        if exists("cfgRow-mail-side-address"):
            die("user profile 'side' must NOT render a static managed row")

        # ── (3) static enable label INSTEAD of the toggle for enabledByNix ─
        for name in ("signal", "caldav"):
            if not visible(f"enableManagedLabel-{name}"):
                die(f"{name} (enabledByNix) should show a static enable label")
            if exists(f"enableToggle-{name}"):
                die(f"{name} (enabledByNix) must NOT render an enable/disable toggle")
        # Contrast: mail has no Nix verdict, so it keeps the toggle and shows
        # no managed enable label.
        if not exists("enableToggle-mail"):
            die("mail (no Nix verdict) should keep its enable/disable toggle")
        if exists("enableManagedLabel-mail"):
            die("mail (no Nix verdict) must NOT show a managed enable label")

        # ── (4) add-account input present on the multiProfile integration ──
        if not visible("addProfileInput-mail"):
            die("multiProfile 'mail' should keep its add-account input")
        # Contrast: a single-account integration hides the add-account input
        # (Qt propagates the parent block's visible:false), so it is present
        # in the tree but not shown.
        if visible("addProfileInput-signal"):
            die("single-account 'signal' must NOT show a visible add-account input")

        # ── (5) add-profile draft with a managed name is blocked ───────────
        if ipc("setText", "addProfileInput-mail", "work") != "ok":
            die("could not type into the add-account input")
        if not wait_until(lambda: visible("draftError-mail"), timeout_s=10):
            die("typing a managed profile name 'work' should surface draftError-mail")
        if exists("cfgInput-mail-work-address"):
            die("draft naming a managed profile must NOT instantiate a draft editor")
        # Contrast: a FREE name clears the error and opens the draft editor —
        # the block is name-specific, not a blanket disable.
        if ipc("setText", "addProfileInput-mail", "newacct") != "ok":
            die("could not retype the add-account input")
        if not wait_until(lambda: not visible("draftError-mail"), timeout_s=10):
            die("a free draft name should clear draftError-mail")
        if not wait_until(
            lambda: exists("cfgInput-mail-newacct-address"), timeout_s=10
        ):
            die(
                "a free draft name should open the draft editor (cfgInput-mail-newacct-*)"
            )

        # ── broker rejections carry the exact §10.5 contract messages ──────
        rejects = [
            (
                {"op": "enable", "integration": "signal"},
                "integration 'signal' enable state is managed by system configuration",
            ),
            (
                {"op": "disable", "integration": "signal"},
                "integration 'signal' enable state is managed by system configuration",
            ),
            (
                {"op": "enable", "integration": "caldav"},
                "integration 'caldav' enable state is managed by system configuration",
            ),
            (
                {
                    "op": "set-field",
                    "integration": "mail",
                    "profile": "work",
                    "field": "address",
                    "value": "x",
                },
                "profile 'work' is managed by system configuration",
            ),
            (
                {"op": "remove-profile", "integration": "mail", "profile": "personal"},
                "profile 'personal' is managed by system configuration",
            ),
        ]
        for req, msg in rejects:
            reply = probe(sock_path, req)
            if reply.get("op") != "error" or reply.get("error") != msg:
                die(f"broker should reject {req} with {msg!r}, got {reply!r}")
        # Writes to UNmanaged targets still succeed (managed lock is per-target).
        for req in (
            {
                "op": "set-field",
                "integration": "mail",
                "profile": "side",
                "field": "address",
                "value": "x",
            },
            {"op": "enable", "integration": "mail"},
        ):
            reply = probe(sock_path, req)
            if reply.get("op") != "ok":
                die(f"broker should accept unmanaged write {req}, got {reply!r}")

        sys.stderr.write(
            "PASS: managed lock badge + static rows + hidden edit/remove + "
            "static enable label + add-account gate + draft block + rejections\n"
        )
    finally:
        qs.stop()
        reap(broker)


if __name__ == "__main__":
    main()
