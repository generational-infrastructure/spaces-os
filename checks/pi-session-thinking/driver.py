#!/usr/bin/env python3
"""Component test for thinking display in the chat plugin.

Injects mock pi RPC events (thinking_start / thinking_delta /
thinking_end) into PiSession via quickshell IPC and asserts:

  1. thinking_start creates a type="thinking" bubble with state="streaming"
  2. thinking_delta appends text to the bubble
  3. thinking_end finalises the bubble (state="sent", full content)
  4. empty thinking blocks (no deltas) are removed on end
  5. thinking bubbles don't interfere with normal text bubbles

No pi-sessiond, no executor, no LLM, no compositor — events are injected
straight into PiSession._handleEvent. ~3s.
"""

import json
import os
import sys

from qs_harness import Quickshell, fail, qs_env, stage_shell


def find_msg(msgs, **criteria):
    for m in msgs:
        if all(m.get(k) == v for k, v in criteria.items()):
            return m
    return None


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    workspace = os.path.join(work_dir, "workspace")
    os.makedirs(workspace, exist_ok=True)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir, extra={"TEST_WORKSPACE": workspace})

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:thinking")
    qs.start()

    def inject(event):
        qs.ipc("injectEvent", json.dumps(event))

    def get_messages():
        return json.loads(qs.ipc("messages"))

    def cleanup():
        qs.stop()
        qs.dump_logs()

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # ── Test 1: thinking_start → thinking_delta → thinking_end ──

        # Simulate agent_start (sets typing=true).
        inject({"type": "agent_start"})

        # thinking_start.
        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_start",
                    "contentIndex": 0,
                },
            },
        )

        msgs = get_messages()
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
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_delta",
                    "contentIndex": 0,
                    "delta": "this problem.",
                },
            },
        )

        msgs = get_messages()
        thinking = find_msg(msgs, id=thinking_id)
        if not thinking:
            cleanup()
            fail("thinking bubble disappeared after deltas")
        if thinking["text"] != "Let me analyze this problem.":
            cleanup()
            fail(f"thinking text mismatch: {thinking['text']!r}")

        # thinking_end.
        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_end",
                    "contentIndex": 0,
                    "content": "Let me analyze this problem.",
                },
            },
        )

        msgs = get_messages()
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
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_start"},
            },
        )
        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_delta",
                    "delta": "Here is the answer.",
                },
            },
        )
        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_end",
                    "content": "Here is the answer.",
                },
            },
        )
        inject(
            {
                "type": "agent_end",
                "messages": [],
            },
        )

        msgs = get_messages()
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

        inject({"type": "agent_start"})
        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_start",
                    "contentIndex": 0,
                },
            },
        )

        msgs = get_messages()
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
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_end",
                    "contentIndex": 0,
                    "content": "",
                },
            },
        )

        msgs = get_messages()
        if find_msg(msgs, id=empty_id):
            cleanup()
            fail("empty thinking bubble should have been removed")

        inject({"type": "agent_end", "messages": []})

        print("OK")
    finally:
        cleanup()


if __name__ == "__main__":
    main()
