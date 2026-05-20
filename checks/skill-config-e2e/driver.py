#!/usr/bin/env python3
"""End-to-end skill-config prompt round-trip test.

Exercises the REAL production path:

  1. Start the skill-config-daemon.
  2. Boot quickshell (offscreen) with the test shell that subscribes
     to the daemon socket and pushes prompt bubbles into PiSession.
  3. Run the actual `skill-config request-input` CLI binary against
     a staged test-skill with a known schema — exactly as pi would
     inside a sandboxed scope.
  4. Assert a `type:"prompt"` bubble with `promptState:"pending"`
     appears in the session's messages (via qs ipc).
  5. Submit a value through the QML IPC handler (simulating the user
     filling in the popup).
  6. Assert the CLI process exits 0 (value was saved).
  7. Assert the bubble state transitions to `"submitted"`.

No pi process, no LLM, no compositor. ~5s.
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
    """Copy shell.qml + PiSession.qml + Commons/ into work_dir/shell."""
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


def stage_systemd_run_stub(work_dir: str) -> str:
    """Install systemd-run stub into work_dir/bin."""
    bin_dir = os.path.join(work_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    dst = os.path.join(bin_dir, "systemd-run")
    with open(dst, "w") as f:
        f.write("#!/usr/bin/env bash\n")
        f.write('while [[ "$1" != "--" ]] && [[ $# -gt 0 ]]; do shift; done\n')
        f.write("shift\n")
        f.write('exec "$@"\n')
    os.chmod(dst, 0o755)
    return bin_dir


def stage_test_skill(state_dir: str) -> None:
    """Create a minimal test-skill in skills-defs with a known schema."""
    skill_dir = os.path.join(state_dir, "skills-defs", "test-skill")
    os.makedirs(skill_dir, exist_ok=True)
    with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
        f.write(
            "---\n"
            "name: Test Skill\n"
            "description: Fixture skill for integration testing.\n"
            "config:\n"
            "  url: Server URL for the test service.\n"
            "secrets:\n"
            "  token: Secret access token.\n"
            "---\n"
            "\n"
            "This skill exists only in the test harness.\n"
        )


# ── quickshell IPC ────────────────────────────────────────────────


def qs_ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:skill", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


# ── main ──────────────────────────────────────────────────────────


def main():
    (daemon_bin, skill_config_bin, qs_bin, test_dir, plugin_dir, work_dir) = sys.argv[
        1:7
    ]

    # Directories.
    state_dir = os.path.join(work_dir, "state")
    agent_dir = os.path.join(state_dir, "pi-agent")
    sessions_dir = os.path.join(state_dir, "sessions", "test")
    skill_config_store = os.path.join(state_dir, "skill-config")
    workspace = os.path.join(work_dir, "workspace")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    sock_path = os.path.join(xdg_runtime, "distro-skill-config.sock")
    for d in [
        state_dir,
        agent_dir,
        sessions_dir,
        skill_config_store,
        workspace,
        xdg_runtime,
    ]:
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # Minimal pi settings.
    with open(os.path.join(agent_dir, "settings.json"), "w") as f:
        json.dump({"extensions": [], "skills": []}, f)

    # Stage a test skill in skills-defs — same layout the NixOS
    # module creates via tmpfiles symlinks.
    stage_test_skill(state_dir)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")
    bin_dir = stage_systemd_run_stub(work_dir)

    env = {
        "HOME": work_dir,
        "PATH": bin_dir + ":" + os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "TEST_STATE_DIR": state_dir,
        "TEST_AGENT_DIR": agent_dir,
        "TEST_WORKSPACE": workspace,
        "TEST_SKILL_SOCK": sock_path,
    }

    # CLI env: daemon socket + state dir (so it finds skills-defs).
    cli_env = dict(env)
    cli_env["SKILL_CONFIG_SOCKET"] = sock_path
    cli_env["DISTRO_PI_CHAT_STATE_DIR"] = state_dir

    # 1. Start skill-config-daemon.
    daemon_env = dict(env)
    daemon_env["SKILL_CONFIG_SOCKET"] = sock_path
    daemon_proc = subprocess.Popen(
        [daemon_bin],
        env=daemon_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    if not wait_until(lambda: os.path.exists(sock_path), timeout_s=5):
        daemon_proc.kill()
        fail("skill-config-daemon never created socket")

    # 2. Start quickshell.
    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    # Track the CLI process once launched.
    cli_proc = None

    def cleanup():
        if cli_proc and cli_proc.poll() is None:
            cli_proc.kill()
        qs_proc.terminate()
        daemon_proc.terminate()
        qs_proc.wait(timeout=5)
        daemon_proc.wait(timeout=5)

        def dump(label, path):
            if os.path.isfile(path):
                try:
                    sys.stderr.write(f"\n== {label} ==\n")
                    sys.stderr.write(open(path).read())
                except Exception:
                    pass

        dump("qs.stdout.log", os.path.join(work_dir, "qs.stdout.log"))
        dump("qs.stderr.log", os.path.join(work_dir, "qs.stderr.log"))

        # Dump qslog if present.
        qs_rt = os.path.join(xdg_runtime, "quickshell")
        if os.path.isdir(qs_rt):
            for dirpath, _dirnames, filenames in os.walk(qs_rt):
                for fn in filenames:
                    fpath = os.path.join(dirpath, fn)
                    try:
                        data = open(fpath, errors="replace").read()
                        sys.stderr.write(f"\n== {fpath} ==\n{data}\n")
                    except Exception:
                        sys.stderr.write(f"\n== {fpath} ==\n<unreadable>\n")

    try:
        # Wait for IPC handler.
        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode != 0:
                sys.stderr.write(
                    f"[ipc_ready] exit={r.returncode} stderr={r.stderr!r}\n"
                )
                return False
            return "test:skill" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup()
            fail("quickshell never bound the test:skill IPC target")

        # Give the subscriber a moment to connect to the daemon.
        time.sleep(0.5)

        # 3. Run the REAL skill-config CLI (same binary pi uses).
        #    request-input blocks until submitted/cancelled/timeout.
        cli_proc = subprocess.Popen(
            [
                skill_config_bin,
                "request-input",
                "test-skill.default.url",
                "--timeout",
                "30",
            ],
            env=cli_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # The CLI should still be running (blocking on the daemon).
        time.sleep(0.3)
        if cli_proc.poll() is not None:
            cleanup()
            fail(
                f"skill-config request-input exited immediately "
                f"(code={cli_proc.returncode}):\n"
                f"stdout: {cli_proc.stdout.read()!r}\n"
                f"stderr: {cli_proc.stderr.read()!r}"
            )

        # 4. Poll for the prompt bubble.
        def has_prompt_bubble():
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            try:
                msgs = json.loads(raw)
            except Exception:
                return False
            return any(
                m.get("type") == "prompt"
                and m.get("promptState") == "pending"
                and m.get("promptField") == "url"
                and m.get("promptSkill") == "test-skill"
                for m in msgs
            )

        if not wait_until(has_prompt_bubble, timeout_s=10):
            # CLI might have crashed after all.
            if cli_proc.poll() is not None:
                cleanup()
                fail(
                    f"skill-config exited (code={cli_proc.returncode}) "
                    f"before bubble appeared:\n"
                    f"stdout: {cli_proc.stdout.read()!r}\n"
                    f"stderr: {cli_proc.stderr.read()!r}"
                )
            cleanup()
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            fail(
                f"expected a prompt bubble with field='url' and "
                f"promptState='pending', got messages={raw}"
            )

        # Find the request_id from the bubble.
        raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
        msgs = json.loads(raw)
        prompt = next(
            m
            for m in msgs
            if m.get("type") == "prompt" and m.get("promptField") == "url"
        )
        request_id = prompt["id"]

        # 5. Submit a value through the QML IPC handler.
        qs_ipc_call(
            qs_bin, shell_qml, env, "submit", request_id, "https://test.example.com/api"
        )

        # 6. CLI should exit 0 with "saved ..." on stdout.
        try:
            cli_stdout, cli_stderr = cli_proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            cli_proc.kill()
            cleanup()
            fail("skill-config request-input didn't exit after submit")

        if cli_proc.returncode != 0:
            cleanup()
            fail(
                f"skill-config exited {cli_proc.returncode} after submit:\n"
                f"stdout: {cli_stdout!r}\nstderr: {cli_stderr!r}"
            )
        if "saved" not in cli_stdout:
            cleanup()
            fail(f"expected 'saved' in CLI stdout, got: {cli_stdout!r}")

        # 7. Bubble should have transitioned to "submitted".
        def bubble_submitted():
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            try:
                msgs = json.loads(raw)
            except Exception:
                return False
            return any(
                m.get("id") == request_id and m.get("promptState") == "submitted"
                for m in msgs
            )

        if not wait_until(bubble_submitted, timeout_s=5):
            cleanup()
            raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
            fail(f"prompt bubble never transitioned to 'submitted', messages={raw}")

        # 8. Verify the value was persisted to config.toml.
        import tomllib

        config_path = os.path.join(skill_config_store, "config.toml")
        if not os.path.isfile(config_path):
            cleanup()
            fail(f"config.toml not created at {config_path}")
        with open(config_path, "rb") as f:
            config = tomllib.load(f)
        stored = config.get("test-skill", {}).get("default", {}).get("url")
        if stored != "https://test.example.com/api":
            cleanup()
            fail(
                f"expected url='https://test.example.com/api' in config.toml, got {stored!r}"
            )

        print("OK")
    finally:
        cleanup()


if __name__ == "__main__":
    main()
