#!/usr/bin/env python3
"""Component test for the chat history's scroll behaviour (issue #28).

The chat history is a BottomToTop ListView whose model is the reversed
`chat.messages` array. Every streaming token reassigns that array and
regrows the newest bubble; the model-driven relayout then re-anchors the
view to the newest message (the visual bottom). With nothing holding the
position that snap yanks a reader who had scrolled up back to the bottom
on *every token* — so you cannot read scrollback while the agent types.

This guards both halves of the fix:

  * REGRESSION — scrolled up, then the agent streams: the view must stay
    put (Qt's `atYEnd` stays false) and hold the same messages on screen
    (the gap from the top of content, contentY - originY, is invariant).
  * FOLLOW — pinned to the newest message: streaming must keep it pinned
    (`atYEnd` stays true), and a message arriving while scrolled up must
    feed the unread pill (`unseen` increments) instead of snapping down.

Headless quickshell, offscreen platform. No compositor, no pi, no LLM.
"""

import os
import sys
import time

from qs_harness import Quickshell, qs_env, stage_shell, wait_until

TARGET = "scroll"


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir)

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target=TARGET)
    qs.start()

    call = qs.ipc
    die = qs.die

    def num(name: str) -> float:
        v = call(name)
        try:
            return float(v)
        except ValueError as e:
            die(f"{name} returned non-numeric {v!r}: {e}")

    def settle():
        # Let the flick animation / Qt.callLater restore run to completion.
        wait_until(lambda: call("moving") == "false", timeout_s=5, interval_s=0.1)
        time.sleep(0.2)

    try:

        def ipc_ready():
            try:
                call("count", timeout=5)
            except (RuntimeError, OSError):
                return False
            return True

        if not wait_until(ipc_ready, timeout_s=30, interval_s=0.1):
            die("quickshell never bound the test IPC target")

        # ── seed a tall, scrollable history ─────────────────────────────
        call("populate", "40")
        time.sleep(0.6)
        if call("count") != "40":
            die(f"history count={call('count')!r}, expected 40 after populate")

        # ── FOLLOW: a fresh open lands pinned to the newest message ─────
        if call("atYEnd") != "true":
            die(
                "after populate the view is not pinned to the newest message (atYEnd != true)"
            )
        # Stream while pinned — must keep following the newest bubble.
        for _ in range(8):
            call("streamDelta")
            time.sleep(0.08)
        settle()
        if call("atYEnd") != "true":
            die(
                "streaming unpinned a reader who was at the bottom (atYEnd flipped to false)"
            )
        sys.stderr.write(
            "PASS: streaming keeps a bottom-pinned reader following the newest message\n"
        )

        # ── REGRESSION: scroll up, then stream — must not be yanked ─────
        # Flick toward older messages until we're genuinely off the bottom.
        for _ in range(15):
            call("flick", "4000")
            settle()
            if call("atYEnd") == "false":
                break
        if call("atYEnd") != "false":
            die("could not scroll up off the bottom with flick (test setup)")

        y0 = num("contentY")
        o0 = num("originY")
        gap0 = y0 - o0  # distance from the top of content; invariant we defend

        for _ in range(10):
            call("streamDelta")
            time.sleep(0.08)
        settle()

        if call("atYEnd") == "true":
            die(
                "streaming yanked the scrolled-up reader back to the bottom "
                "(atYEnd snapped to true) — issue #28 regression"
            )
        y1 = num("contentY")
        o1 = num("originY")
        gap1 = y1 - o1
        drift = abs(gap1 - gap0)
        if drift > 4.0:
            die(
                f"scroll position drifted by {drift:.1f}px while streaming "
                f"(gap {gap0:.1f} -> {gap1:.1f}); scrollback not held steady"
            )
        sys.stderr.write(
            f"PASS: streaming holds the scrolled-up view (atYEnd=false, drift={drift:.1f}px)\n"
        )

        # ── PILL: a new message while scrolled up counts, never snaps ───
        before = int(float(call("unseen")))
        call("appendMsg")
        time.sleep(0.3)
        settle()
        if call("atYEnd") == "true":
            die("an appended message yanked the scrolled-up reader to the bottom")
        after = int(float(call("unseen")))
        if after <= before:
            die(
                f"unread pill did not count the appended message (unseen {before} -> {after})"
            )
        sys.stderr.write(
            f"PASS: a message arriving while scrolled up counts ({before} -> {after}) and holds position\n"
        )
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
