#!/usr/bin/env python3
"""Spaces Voice Indicator — WARNING visual-mapping test.

Loads the plugin's real BarWidget.qml in a headless quickshell against stub
noctalia singletons, drives the service state over IPC, and asserts the
glyph / colour / tooltip / visibility the bar derives — the colour-and-tooltip
contract that agent-vm would otherwise have to screenshot.

Asserts, against noctalia's default dark palette:

  idle                       → dim mic (mOnSurfaceVariant), tooltip-idle, shown
  idle + qualityWarning      → caution mic (mTertiary), tooltip-no-speech, shown
                               — and distinct from BOTH recording and transcribing
  recording                  → red mic (mError), tooltip-recording
  transcribing               → amber loader-2 (mPrimary), tooltip-transcribing
  hideWhenIdle + idle        → hidden …
  hideWhenIdle + warning     → … but the warning forces it visible again

Headless quickshell, offscreen platform. No noctalia, no compositor. ~3-10s.
"""

import os
import sys

from qs_harness import Quickshell, qs_env, stage_shell, wait_until

# Noctalia default-dark palette (mirrors the stub Color singleton).
C_ERROR = "fd4663"  # recording
C_PRIMARY = "fff59b"  # transcribing
C_TERTIARY = "9bfece"  # no-speech warning
C_IDLE = "7c80b4"  # idle (mOnSurfaceVariant)


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    # BarWidget.qml is the unit under test; stage ONLY it so shell.qml
    # resolves `BarWidget {}` from the shell root. The stub noctalia
    # subtree (stub/{Commons,Services,Widgets}) is overlaid AT the shell
    # root so `import qs.Commons` etc. resolve via quickshell's
    # `qs` = shell-root convention.
    shell_root = stage_shell(
        test_dir,
        plugin_dir,
        work_dir,
        plugin_files=["BarWidget.qml"],
        overlay_dirs=[test_dir, os.path.join(test_dir, "stub")],
    )
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir)

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:bar")
    qs.start()

    die = qs.die
    call = qs.ipc

    def set_voice(s: str):
        call("setVoice", s)

    def set_warning(w: str):
        call("setWarning", w)

    def set_hide(b: str):
        call("setHideWhenIdle", b)

    def color() -> str:
        return call("color").lower()

    def expect_color(hex6: str, label: str):
        got = color()
        if hex6 not in got:
            die(f"{label}: expected colour ~#{hex6}, got {got!r}")

    def expect(fn, want: str, label: str):
        if not wait_until(lambda: fn() == want, timeout_s=6):
            die(f"{label}: expected {want!r}, got {fn()!r}")

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # Idle baseline: dim mic, idle tooltip, visible.
        set_voice("idle")
        set_warning("")
        expect(lambda: call("glyph"), "microphone", "idle glyph")
        expect(lambda: call("tooltip"), "voice.tooltip-idle", "idle tooltip")
        expect(lambda: call("shown"), "1", "idle shown")
        expect_color(C_IDLE, "idle colour")

        # No-speech warning on the idle glyph: caution tone + matching tooltip.
        set_warning("no_speech")
        expect(lambda: call("tooltip"), "voice.tooltip-no-speech", "warning tooltip")
        expect(lambda: call("glyph"), "microphone", "warning glyph stays mic")
        expect(lambda: call("shown"), "1", "warning shown")
        expect_color(C_TERTIARY, "warning colour is mTertiary")
        # The caution tone MUST be distinct from both busy states.
        warn_c = color()
        if C_ERROR in warn_c or C_PRIMARY in warn_c:
            die(
                f"warning colour must differ from recording/transcribing, got {warn_c!r}"
            )

        # Recording: red mic.
        set_warning("")
        set_voice("recording")
        expect(lambda: call("tooltip"), "voice.tooltip-recording", "recording tooltip")
        expect_color(C_ERROR, "recording colour")

        # Transcribing: amber spinner glyph.
        set_voice("transcribing")
        expect(lambda: call("glyph"), "loader-2", "transcribing glyph")
        expect(
            lambda: call("tooltip"),
            "voice.tooltip-transcribing",
            "transcribing tooltip",
        )
        expect_color(C_PRIMARY, "transcribing colour")

        # hideWhenIdle: idle is hidden …
        set_voice("idle")
        set_warning("")
        set_hide("true")
        expect(lambda: call("shown"), "0", "hideWhenIdle hides idle")
        # … but a pending warning forces the glyph back visible.
        set_warning("no_speech")
        expect(lambda: call("shown"), "1", "warning overrides hideWhenIdle")
        expect_color(C_TERTIARY, "warning colour under hideWhenIdle")

        sys.stderr.write("PASS: voice indicator warning visual mapping holds\n")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
