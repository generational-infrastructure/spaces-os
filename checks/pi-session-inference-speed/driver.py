#!/usr/bin/env python3
"""Component test for inference-speed (tokens/second) attribution.

Injects mock pi RPC events into PiSession via quickshell IPC and asserts:

  1. message_end with role=assistant + usage.output computes tps from
     wall-clock since the first text_start of the assistant message and
     patches the text bubble with `tps` and `outputTokens`.
  2. message_end with usage.output=0 leaves the bubble untouched.
  3. message_end before any text_start does not crash and leaves
     existing bubbles untouched.
  4. agent_end resets the tps clock so the next assistant message
     starts fresh.

Elapsed time is pinned by backdating PiSession._assistantStartedAt via
IPC right before the message_end injection, so the assertion compares
a deterministic elapsed delta to the computed tps — not Date.now()
itself.

No pi-sessiond, no executor, no LLM, no compositor — events are injected
straight into PiSession._handleEvent. ~3s.
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
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:tps", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def inject(qs_bin, shell_qml, env, event):
    qs_ipc_call(qs_bin, shell_qml, env, "injectEvent", json.dumps(event))


def set_elapsed(qs_bin, shell_qml, env, elapsed_ms):
    qs_ipc_call(qs_bin, shell_qml, env, "setElapsedMs", str(elapsed_ms))


def get_started_at(qs_bin, shell_qml, env):
    return int(qs_ipc_call(qs_bin, shell_qml, env, "startedAt").strip())


def get_messages(qs_bin, shell_qml, env):
    raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
    return json.loads(raw)


def find_msg(msgs, **criteria):
    for m in msgs:
        if all(m.get(k) == v for k, v in criteria.items()):
            return m
    return None


def assistant_message(output_tokens):
    return {
        "role": "assistant",
        "content": [{"type": "text", "text": "hello world"}],
        "api": "openai",
        "provider": "openai",
        "model": "test",
        "usage": {
            "input": 10,
            "output": output_tokens,
            "cacheRead": 0,
            "cacheWrite": 0,
            "totalTokens": 10 + output_tokens,
            "cost": {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0,
                "total": 0,
            },
        },
        "stopReason": "stop",
        "timestamp": 1700000000000,
    }


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    workspace = os.path.join(work_dir, "workspace")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in [workspace, xdg_runtime]:
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "TEST_WORKSPACE": workspace,
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def cleanup():
        qs_proc.terminate()
        qs_proc.wait(timeout=5)
        for label, name in [
            ("qs.stdout", "qs.stdout.log"),
            ("qs.stderr", "qs.stderr.log"),
        ]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:tps" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup()
            fail("quickshell never bound the test:tps IPC target")

        # ── Test 1: tps = usage.output / elapsed_seconds ──
        # 100 tokens over a pinned 2 s elapsed window → 50.0 t/s.

        inject(qs_bin, shell_qml, env, {"type": "agent_start"})
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_start", "contentIndex": 0},
            },
        )
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_delta",
                    "contentIndex": 0,
                    "delta": "hello world",
                },
            },
        )
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_end",
                    "contentIndex": 0,
                    "content": "hello world",
                },
            },
        )

        set_elapsed(qs_bin, shell_qml, env, 2_000)
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_end",
                "message": assistant_message(100),
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        text_bubble = find_msg(msgs, type="", text="hello world")
        if not text_bubble:
            cleanup()
            fail(f"no text bubble after text_start/end: {msgs}")
        tps = text_bubble.get("tps", 0)
        # Tolerance covers IPC round-trip jitter between setElapsedMs and
        # the message_end injection (~10-50 ms typically).
        if abs(tps - 50.0) > 2.0:
            cleanup()
            fail(f"expected tps≈50.0 (±2.0), got {tps!r} in {text_bubble}")
        if text_bubble.get("outputTokens") != 100:
            cleanup()
            fail(f"expected outputTokens=100, got {text_bubble.get('outputTokens')!r}")

        # ── Test 2: agent_end resets _assistantStartedAt ──

        inject(qs_bin, shell_qml, env, {"type": "agent_end", "messages": []})
        if get_started_at(qs_bin, shell_qml, env) != 0:
            cleanup()
            fail("agent_end did not reset _assistantStartedAt to 0")

        # ── Test 3: message_end with output=0 is a no-op ──

        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_start", "contentIndex": 0},
            },
        )
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_delta",
                    "contentIndex": 0,
                    "delta": "second",
                },
            },
        )
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_end",
                    "contentIndex": 0,
                    "content": "second",
                },
            },
        )
        set_elapsed(qs_bin, shell_qml, env, 1_000)
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_end",
                "message": assistant_message(0),
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        second = find_msg(msgs, type="", text="second")
        if not second:
            cleanup()
            fail(f"no second text bubble: {msgs}")
        if second.get("tps", 0) > 0:
            cleanup()
            fail(f"expected no tps for output=0, got {second.get('tps')!r}")

        # ── Test 4: message_end before any text bubble is a safe no-op ──

        inject(qs_bin, shell_qml, env, {"type": "agent_end", "messages": []})
        before_count = len(get_messages(qs_bin, shell_qml, env))
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_end",
                "message": assistant_message(50),
            },
        )
        after_count = len(get_messages(qs_bin, shell_qml, env))
        if before_count != after_count:
            cleanup()
            fail(
                f"message_end without prior text_start mutated bubbles: "
                f"before={before_count} after={after_count}"
            )

        print("PASS")
    finally:
        cleanup()


if __name__ == "__main__":
    main()
