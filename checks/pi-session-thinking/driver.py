#!/usr/bin/env python3
"""Component test for thinking display in the chat plugin.

Injects mock pi RPC events (thinking_start / thinking_delta /
thinking_end) into PiSession via quickshell IPC and asserts:

  1. thinking_start creates a type="thinking" bubble with state="streaming"
  2. thinking_delta appends text to the bubble
  3. thinking_end finalises the bubble (state="sent", full content)
  4. empty thinking blocks (no deltas) are removed on end
  5. thinking bubbles don't interfere with normal text bubbles

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
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:thinking", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout


def inject(qs_bin, shell_qml, env, event):
    qs_ipc_call(qs_bin, shell_qml, env, "injectEvent", json.dumps(event))


def get_messages(qs_bin, shell_qml, env):
    raw = qs_ipc_call(qs_bin, shell_qml, env, "messages")
    return json.loads(raw)


def find_msg(msgs, **criteria):
    for m in msgs:
        if all(m.get(k) == v for k, v in criteria.items()):
            return m
    return None


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    state_dir = os.path.join(work_dir, "state")
    agent_dir = os.path.join(state_dir, "pi-agent")
    workspace = os.path.join(work_dir, "workspace")
    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    for d in [state_dir, agent_dir, workspace, xdg_runtime]:
        os.makedirs(d, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    with open(os.path.join(agent_dir, "settings.json"), "w") as f:
        json.dump({"extensions": [], "skills": []}, f)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "TEST_STATE_DIR": state_dir,
        "TEST_AGENT_DIR": agent_dir,
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
        # Wait for IPC.
        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:thinking" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            cleanup()
            fail("quickshell never bound the test:thinking IPC target")

        # ── Test 1: thinking_start → thinking_delta → thinking_end ──

        # Simulate agent_start (sets typing=true).
        inject(qs_bin, shell_qml, env, {"type": "agent_start"})

        # thinking_start.
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_start",
                    "contentIndex": 0,
                },
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        thinking = find_msg(msgs, type="thinking")
        if not thinking:
            cleanup()
            fail(f"thinking_start did not create a thinking bubble: {msgs}")
        if thinking["state"] != "streaming":
            cleanup()
            fail(
                f"thinking bubble should have state='streaming', got {thinking['state']!r}"
            )
        thinking_id = thinking["id"]

        # thinking_delta — two chunks.
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_delta",
                    "contentIndex": 0,
                    "delta": "Let me analyze ",
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
                    "type": "thinking_delta",
                    "contentIndex": 0,
                    "delta": "this problem.",
                },
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        thinking = find_msg(msgs, id=thinking_id)
        if not thinking:
            cleanup()
            fail("thinking bubble disappeared after deltas")
        if thinking["text"] != "Let me analyze this problem.":
            cleanup()
            fail(f"thinking text mismatch: {thinking['text']!r}")

        # thinking_end.
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_end",
                    "contentIndex": 0,
                    "content": "Let me analyze this problem.",
                },
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        thinking = find_msg(msgs, id=thinking_id)
        if not thinking:
            cleanup()
            fail("thinking bubble gone after thinking_end")
        if thinking["state"] != "sent":
            cleanup()
            fail(
                f"thinking bubble state after end: {thinking['state']!r}, expected 'sent'"
            )

        # ── Test 2: text follows thinking in same turn ──

        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_start"},
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
                    "delta": "Here is the answer.",
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
                    "content": "Here is the answer.",
                },
            },
        )
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "agent_end",
                "messages": [],
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        # Must have both a thinking and a text bubble.
        thinking = find_msg(msgs, id=thinking_id)
        text_bubble = find_msg(msgs, type="", state="sent")
        if not thinking:
            cleanup()
            fail("thinking bubble missing after full turn")
        if not text_bubble:
            cleanup()
            fail(f"text bubble missing after full turn, messages={msgs}")
        if text_bubble["text"] != "Here is the answer.":
            cleanup()
            fail(f"text bubble text: {text_bubble['text']!r}")

        # ── Test 3: empty thinking block gets removed ──

        inject(qs_bin, shell_qml, env, {"type": "agent_start"})
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_start",
                    "contentIndex": 0,
                },
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        empty_thinking = [
            m
            for m in msgs
            if m.get("type") == "thinking" and m.get("id") != thinking_id
        ]
        if len(empty_thinking) != 1:
            cleanup()
            fail(f"expected 1 new thinking bubble, got {len(empty_thinking)}")
        empty_id = empty_thinking[0]["id"]

        # End with no deltas and no content.
        inject(
            qs_bin,
            shell_qml,
            env,
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_end",
                    "contentIndex": 0,
                    "content": "",
                },
            },
        )

        msgs = get_messages(qs_bin, shell_qml, env)
        if find_msg(msgs, id=empty_id):
            cleanup()
            fail("empty thinking bubble should have been removed")

        inject(qs_bin, shell_qml, env, {"type": "agent_end", "messages": []})

        print("OK")
    finally:
        cleanup()


if __name__ == "__main__":
    main()
