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

Usage: driver.py <qs_bin> <registry_js> <test_dir> <work_dir>
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


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, registry_js: str, work_dir: str) -> str:
    """Drop SessionRegistry.js next to the test shell.qml so the module
    import resolves the same way it does beside the production QML."""
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(registry_js, os.path.join(shell_root, "SessionRegistry.js"))
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    return shell_root


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <registry_js> <test_dir> <work_dir>")
    qs_bin, registry_js, test_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in (home, xdg_runtime):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, registry_js, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = os.environ.copy()
    env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "LC_ALL": "C.UTF-8",
            "LANG": "C.UTF-8",
            "PYTHONUTF8": "1",
        }
    )

    def call(payload) -> object:
        cmd = [
            qs_bin,
            "ipc",
            "-p",
            shell_qml,
            "call",
            "test:registry",
            "run",
            json.dumps(payload),
        ]
        out = subprocess.run(
            cmd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20
        )
        if out.returncode != 0:
            raise RuntimeError(
                f"run ipc failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        got = json.loads(out.stdout.strip())
        if isinstance(got, dict) and "_error" in got:
            raise RuntimeError(f"run: {got['_error']}")
        return got

    qs_log = open(os.path.join(work_dir, "qs.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml], env=env, stdout=qs_log, stderr=qs_log
    )

    def die(msg):
        p = os.path.join(work_dir, "qs.log")
        if os.path.isfile(p):
            sys.stderr.write("\n== qs.log ==\n")
            sys.stderr.write(open(p, errors="replace").read()[-6000:])
        fail(msg)

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

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:registry" in r.stdout

        if not wait_until(ipc_ready, timeout_s=30):
            die("quickshell never bound the test:registry IPC target")

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
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
