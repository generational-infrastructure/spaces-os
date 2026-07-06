#!/usr/bin/env python3
"""NComboBox model-name truncation-tooltip component test.

The model dropdown shows a per-row tooltip with the full model name only
when that row's label elides (a trailing "…"). The tooltip is wired as:

    ToolTip.visible: delegateLabel.truncated && delegateItem.hovered
    ToolTip.text:    delegateItem.fullName

A real hover and the windowed Popup can't be synthesised headlessly, so
this drives the real delegate Component directly and checks the two
ingredients the tooltip is built from:

  1. A long label in a NARROW row elides   -> truncated == True
     (so the gate `truncated && hovered` can fire), and `fullName`
     still carries the complete, untruncated string the tip renders.
  2. The SAME label in a WIDE row fits      -> truncated == False
     (so the tooltip stays suppressed when nothing is hidden).

Headless quickshell, offscreen platform. No pi, no LLM. ~3-5s.
"""

import json
import os
import sys

from qs_harness import Quickshell, qs_env, stage_shell, wait_until

# A model label long enough to overflow a narrow row but fit a wide one.
LONG_NAME = "[openrouter] anthropic/claude-3.5-sonnet-20241022-instruct-preview"
NARROW_W = 90
WIDE_W = 1200


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir)

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:combo")
    qs.start()

    ipc = qs.ipc
    die = qs.die

    def probe_at(width: int) -> dict:
        ipc("configure", LONG_NAME, str(width))
        if not wait_until(
            lambda: ipc("ready") == "1",
            timeout_s=10,
        ):
            die(f"delegate never laid out at width {width}")
        return json.loads(ipc("probe"))

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # (1) Narrow row: the long label overflows, so it elides and the
        # tooltip gate can fire — while the tip still carries the full name.
        narrow = probe_at(NARROW_W)
        if narrow.get("fullName") != LONG_NAME:
            die(f"narrow: fullName lost the untruncated label, got {narrow!r}")
        if narrow.get("truncated") is not True:
            die(f"narrow: expected truncated label at {NARROW_W}px, got {narrow!r}")

        # (2) Wide row: the same label fits, so nothing is hidden and the
        # tooltip stays suppressed (truncated False).
        wide = probe_at(WIDE_W)
        if wide.get("fullName") != LONG_NAME:
            die(f"wide: fullName lost the untruncated label, got {wide!r}")
        if wide.get("truncated") is not False:
            die(f"wide: expected no elision at {WIDE_W}px, got {wide!r}")

        sys.stderr.write(
            "PASS: combo row elides + exposes full name only when overflowing\n"
        )
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
