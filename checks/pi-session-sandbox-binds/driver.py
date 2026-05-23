#!/usr/bin/env python3
"""Sandbox-binds contract for PiSession.

Drives PiSession.sandboxBinds through quickshell IPC and asserts the
resulting --property=BindPaths / --property=BindReadOnlyPaths flags
match what each fixture declares. This is the contract every NixOS
module that adds a skill via services.pi-chat.sandboxBinds depends on:
the QML side must turn each declarative entry into exactly one
systemd-run bind property with the right mode, target, and optional
prefix, after expanding %h / %t.

No pi process, no LLM, no compositor. ~3s.
"""

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
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
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
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:sandbox-binds", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def extract_binds(argv: list) -> list:
    """Pull bind-style --property= entries out of a systemd-run argv,
    preserving order so we can assert on duplicates and sequencing.
    Returns [(prop_name, source, target)] tuples — the parsed property
    payload, not the raw flag.
    """
    out = []
    for entry in argv:
        if not entry.startswith("--property="):
            continue
        body = entry[len("--property=") :]
        if "=" not in body:
            continue
        name, _, value = body.partition("=")
        if name not in ("BindPaths", "BindReadOnlyPaths"):
            continue
        src, sep, tgt = value.partition(":")
        if not sep:
            tgt = src
        out.append((name, src, tgt))
    return out


def main() -> None:
    if len(sys.argv) != 5:
        fail("usage: driver.py <qs_bin> <test_dir> <plugin_dir> <work_dir>")
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]
    os.makedirs(work_dir, exist_ok=True)

    home = os.path.join(work_dir, "home")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    agent_dir = os.path.join(work_dir, "agent")
    state_dir = os.path.join(work_dir, "state")
    workspace = os.path.join(work_dir, "workspace")
    for d in (home, xdg_runtime, agent_dir, state_dir, workspace):
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    # Fixtures covering every documented field combination. Keep this
    # list short and exhaustive — one entry per dimension we care about.
    fixtures = [
        {
            "name": "rw default target",
            "input": [{"source": "/host/sock", "mode": "rw"}],
            "expect": [("BindPaths", "/host/sock", "/host/sock")],
        },
        {
            "name": "ro default target",
            "input": [{"source": "/host/ro", "mode": "ro"}],
            "expect": [("BindReadOnlyPaths", "/host/ro", "/host/ro")],
        },
        {
            "name": "explicit different target",
            "input": [{"source": "/host/src", "target": "/sandbox/dst", "mode": "rw"}],
            "expect": [("BindPaths", "/host/src", "/sandbox/dst")],
        },
        {
            "name": "optional prefixes source with -",
            "input": [{"source": "/host/maybe", "mode": "rw", "optional": True}],
            "expect": [("BindPaths", "-/host/maybe", "/host/maybe")],
        },
        {
            "name": "%h expands to HOME",
            "input": [{"source": "%h/.cache/x", "mode": "ro"}],
            "expect": [("BindReadOnlyPaths", f"{home}/.cache/x", f"{home}/.cache/x")],
        },
        {
            "name": "%t expands to XDG_RUNTIME_DIR",
            "input": [{"source": "%t/svc.sock", "mode": "rw"}],
            "expect": [
                ("BindPaths", f"{xdg_runtime}/svc.sock", f"{xdg_runtime}/svc.sock")
            ],
        },
        {
            "name": "%h and %t both in source and target",
            "input": [
                {
                    "source": "%t/agent.sock",
                    "target": "%t/agent.sock",
                    "mode": "rw",
                },
                {
                    "source": "%h/data",
                    "target": "/sandbox/data",
                    "mode": "ro",
                },
            ],
            "expect": [
                ("BindPaths", f"{xdg_runtime}/agent.sock", f"{xdg_runtime}/agent.sock"),
                ("BindReadOnlyPaths", f"{home}/data", "/sandbox/data"),
            ],
        },
        {
            "name": "order preserved across mixed modes",
            "input": [
                {"source": "/a", "mode": "rw"},
                {"source": "/b", "mode": "ro"},
                {"source": "/c", "mode": "rw"},
            ],
            "expect": [
                ("BindPaths", "/a", "/a"),
                ("BindReadOnlyPaths", "/b", "/b"),
                ("BindPaths", "/c", "/c"),
            ],
        },
        {
            "name": "empty list adds nothing",
            "input": [],
            "expect": [],
            "verify_baseline_unchanged": True,
        },
    ]

    base_env = os.environ.copy()
    base_env.update(
        {
            "HOME": home,
            "XDG_RUNTIME_DIR": xdg_runtime,
            "QT_QPA_PLATFORM": "offscreen",
            "QSG_RHI_BACKEND": "null",
            "TEST_STATE_DIR": state_dir,
            "TEST_AGENT_DIR": agent_dir,
            "TEST_WORKSPACE": workspace,
        }
    )

    # First fixture sets the baseline so we can verify "empty list ==
    # no extra binds beyond what PiSession already adds inline" without
    # hard-coding every existing inline bind here. We diff the empty-
    # list run against each fixture and require the delta to match.
    def run_fixture(fixture):
        env = dict(base_env)
        env["TEST_SANDBOX_BINDS"] = json.dumps(fixture["input"])
        qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
        qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
        qs_proc = subprocess.Popen(
            [qs_bin, "-p", shell_qml], env=env, stdout=qs_stdout, stderr=qs_stderr
        )
        try:

            def ipc_ready():
                r = subprocess.run(
                    [qs_bin, "ipc", "-p", shell_qml, "show"],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                return r.returncode == 0 and "test:sandbox-binds" in r.stdout

            if not wait_until(ipc_ready, timeout_s=20):
                qs_stdout.flush()
                qs_stderr.flush()
                with open(os.path.join(work_dir, "qs.stderr.log")) as fh:
                    sys.stderr.write(fh.read())
                fail(f"[{fixture['name']}] IPC never registered")

            raw = qs_ipc_call(qs_bin, shell_qml, env, "buildCommand")
            argv = json.loads(raw)
            return extract_binds(argv)
        finally:
            qs_proc.terminate()
            try:
                qs_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qs_proc.kill()

    # Baseline: empty list. Everything we observe here is PiSession's
    # own inline binds (skill-config socket, workspace, session state,
    # …). Other fixtures must produce that baseline plus exactly the
    # entries they declared.
    baseline = run_fixture({"name": "baseline", "input": []})

    failures = []
    for fixture in fixtures:
        produced = run_fixture(fixture)
        delta = (
            produced[len(baseline) :] if produced[: len(baseline)] == baseline else None
        )
        if delta is None:
            failures.append(
                f"[{fixture['name']}] baseline binds were mutated.\n"
                f"  baseline: {baseline!r}\n"
                f"  produced: {produced!r}"
            )
            continue
        if delta != fixture["expect"]:
            failures.append(
                f"[{fixture['name']}] bind delta mismatch.\n"
                f"  expected: {fixture['expect']!r}\n"
                f"  actual:   {delta!r}"
            )

    if failures:
        sys.stderr.write("\n\n".join(failures) + "\n")
        fail(f"{len(failures)} of {len(fixtures)} sandbox-bind fixtures failed")

    print("OK")


if __name__ == "__main__":
    main()
