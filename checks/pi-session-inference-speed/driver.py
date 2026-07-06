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

Elapsed time is pinned atomically: injectEventWithElapsed backdates
PiSession._assistantStartedAt and injects the message_end in the same
IPC call (one synchronous JS frame), so the assertion compares a
deterministic elapsed delta to the computed tps — no IPC round-trip
latency can leak into the measured window.

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
    os.makedirs(workspace, exist_ok=True)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir, extra={"TEST_WORKSPACE": workspace})

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:tps")
    qs.start()

    def inject(event):
        qs.ipc("injectEvent", json.dumps(event))

    def inject_with_elapsed(elapsed_ms, event):
        qs.ipc("injectEventWithElapsed", str(elapsed_ms), json.dumps(event))

    def get_started_at():
        return int(qs.ipc("startedAt"))

    def get_messages():
        return json.loads(qs.ipc("messages"))

    def cleanup():
        qs.stop()
        qs.dump_logs()

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # ── Test 1: tps = usage.output / elapsed_seconds ──
        # 100 tokens over a pinned 2 s elapsed window → 50.0 t/s.

        inject({"type": "agent_start"})
        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_start", "contentIndex": 0},
            },
        )
        inject(
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
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_end",
                    "contentIndex": 0,
                    "content": "hello world",
                },
            },
        )

        inject_with_elapsed(
            2_000,
            {
                "type": "message_end",
                "message": assistant_message(100),
            },
        )

        msgs = get_messages()
        text_bubble = find_msg(msgs, type="", text="hello world")
        if not text_bubble:
            cleanup()
            fail(f"no text bubble after text_start/end: {msgs}")
        tps = text_bubble.get("tps", 0)
        # Backdate and injection share one JS frame; only a ~1 ms clock
        # tick can drift the window.
        if abs(tps - 50.0) > 0.5:
            cleanup()
            fail(f"expected tps≈50.0 (±0.5), got {tps!r} in {text_bubble}")
        if text_bubble.get("outputTokens") != 100:
            cleanup()
            fail(f"expected outputTokens=100, got {text_bubble.get('outputTokens')!r}")

        # ── Test 2: agent_end resets _assistantStartedAt ──

        inject({"type": "agent_end", "messages": []})
        if get_started_at() != 0:
            cleanup()
            fail("agent_end did not reset _assistantStartedAt to 0")

        # ── Test 3: message_end with output=0 is a no-op ──

        inject(
            {
                "type": "message_update",
                "assistantMessageEvent": {"type": "text_start", "contentIndex": 0},
            },
        )
        inject(
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
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_end",
                    "contentIndex": 0,
                    "content": "second",
                },
            },
        )
        inject_with_elapsed(
            1_000,
            {
                "type": "message_end",
                "message": assistant_message(0),
            },
        )

        msgs = get_messages()
        second = find_msg(msgs, type="", text="second")
        if not second:
            cleanup()
            fail(f"no second text bubble: {msgs}")
        if second.get("tps", 0) > 0:
            cleanup()
            fail(f"expected no tps for output=0, got {second.get('tps')!r}")

        # ── Test 4: message_end before any text bubble is a safe no-op ──

        inject({"type": "agent_end", "messages": []})
        before_count = len(get_messages())
        inject(
            {
                "type": "message_end",
                "message": assistant_message(50),
            },
        )
        after_count = len(get_messages())
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
