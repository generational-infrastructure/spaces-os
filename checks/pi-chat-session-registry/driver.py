#!/usr/bin/env python3
"""Correspondence contract test for programs/pi-chat/SessionRegistry.js.

Replays the table-driven scenario corpus (fixtures/*.json) through the
registry interface inside headless quickshell and asserts:

  * the final index entries each scenario pins (partial match per
    listed key, exact entry count/order),
  * the cutoff (lastImportTime) after the fold,
  * the per-op trace — what each merge added/removed, what each claim
    stamped (partial match per listed key),
  * replay is pure (same scenario twice -> byte-identical JSON).

No daemon, no pi worker, no LLM — the fold is pure.

Usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>
"""

from __future__ import annotations

import json
import os
import sys

from qs_harness import Quickshell, fail, qs_env, stage_shell


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(
        work_dir,
        extra={
            "QSG_RHI_BACKEND": "null",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        },
    )

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:registry")

    def call(payload) -> object:
        out = qs.ipc("run", json.dumps(payload), timeout=20)
        got = json.loads(out)
        if isinstance(got, dict) and "_error" in got:
            raise RuntimeError(f"run: {got['_error']}")
        return got

    qs.start()

    def die(msg):
        qs.die(msg)

    failures: list[str] = []

    def check(label: str, got, want):
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")

    def check_partial(label: str, got: dict, want: dict):
        for k, v in want.items():
            if got.get(k) != v:
                failures.append(f"{label}.{k}: got {got.get(k)!r}, want {v!r}")

    def check_partial_list(label: str, got: list, want: list):
        if len(got) != len(want):
            failures.append(
                f"{label}: got {len(got)} entries, want {len(want)}: {got!r}"
            )
            return
        for i, (g, w) in enumerate(zip(got, want)):
            check_partial(f"{label}[{i}]", g, w)

    try:
        qs.wait_ipc_ready(timeout_s=30)

        fixture_dir = os.path.join(test_dir, "fixtures")
        names = sorted(f for f in os.listdir(fixture_dir) if f.endswith(".json"))
        if not names:
            die("no fixtures found")

        for name in names:
            with open(os.path.join(fixture_dir, name)) as f:
                fx = json.load(f)
            label = name[: -len(".json")]
            got = call({"ops": fx["ops"]})
            expect = fx["expect"]

            check_partial_list(f"{label}.sessions", got["sessions"], expect["sessions"])
            if "lastImportTime" in expect:
                check(
                    f"{label}.lastImportTime",
                    got["lastImportTime"],
                    expect["lastImportTime"],
                )
            check_partial_list(f"{label}.trace", got["trace"], expect["trace"])

            # Purity: the fold is stateless — an identical replay yields
            # an identical result.
            again = call({"ops": fx["ops"]})
            check(f"{label}.pure-replay", again, got)

        if failures:
            die("registry mismatches:\n  " + "\n  ".join(failures))

        print(f"PASS ({len(names)} fixtures)")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
