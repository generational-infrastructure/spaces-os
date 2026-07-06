#!/usr/bin/env python3
"""Spaces Voice Indicator — bar-pulse activation test.

Drives two copies of the plugin's Main.qml service (one with the feature
at its default, one opted out) by writing voxtype's lifecycle word to
$XDG_RUNTIME_DIR/voxtype/state, exactly as the daemon does, and reading
the pulse-driving state back over the quickshell ipc CLI.

Asserts the contract the whole-bar ambient cue relies on:

  1. no file yet      → not recording → pulse OFF (both)
  2. write "idle"     → pulse OFF; default enable flag is ON
  3. write "recording"→ pulse ON for the default host, OFF for the
                        opted-out host (one signal, two policies)
  4. write "streaming"→ pulse ON (live capture also pulses)
  5. write "transcribing" → pulse OFF (capture finished)
  6. remove the file  → pulse OFF (daemon down)

This proves the pulse reuses voxtype's voiceState, activates on
recording/streaming and only then, and that barPulse=false suppresses it
without touching the underlying state. Headless quickshell, offscreen
platform. No voxtype, no compositor. ~3-10s.
"""

import os
import sys

from qs_harness import Quickshell, qs_env, stage_shell, wait_until


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    env = qs_env(work_dir)
    voxtype_dir = os.path.join(env["XDG_RUNTIME_DIR"], "voxtype")
    os.makedirs(voxtype_dir, exist_ok=True)
    state_file = os.path.join(voxtype_dir, "state")

    # Main.qml is the unit under test; stage ONLY it next to shell.qml so
    # the `Main {}` component resolves from the same directory. BarPulse.qml
    # (the layer-shell overlay) is deliberately NOT staged: neither host
    # here arms its LazyLoader, so the noctalia qs.Commons / layer-shell
    # surface is never exercised — this test pins Main.qml's pulse LOGIC.
    shell_root = stage_shell(test_dir, plugin_dir, work_dir, plugin_files=["Main.qml"])
    shell_qml = os.path.join(shell_root, "shell.qml")

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:voicepulse")
    qs.start()

    die = qs.die
    call = qs.ipc

    def write_state(word: str) -> None:
        with open(state_file, "w") as f:
            f.write(word)

    def expect(fn: str, want: str, label: str) -> None:
        if not wait_until(lambda: call(fn) == want, timeout_s=8):
            die(f"{label}: {fn} expected {want!r}, got {call(fn)!r}")

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # The opt-out is a static policy; it must read false the whole time.
        if call("enabledDisabled") != "false":
            die("barPulse=false host must report the feature disabled")

        # (1) No file yet → not recording → pulse off, both hosts.
        expect("stateDefault", "down", "step1 no-file")
        expect("pulseDefault", "false", "step1 default pulse off when down")
        expect("pulseDisabled", "false", "step1 disabled pulse off when down")

        # (2) idle → pulse off, but the feature is enabled by default.
        write_state("idle")
        expect("stateDefault", "idle", "step2 idle")
        expect("pulseDefault", "false", "step2 no pulse while idle")
        expect("enabledDefault", "true", "step2 default barPulse enabled")

        # (3) recording → default host pulses; opted-out host does NOT,
        # even though it sees the very same recording state.
        write_state("recording")
        expect("pulseDefault", "true", "step3 default pulses on recording")
        expect("pulseDisabled", "false", "step3 opt-out suppresses the pulse")

        # (4) streaming is live capture too → pulse on.
        write_state("streaming")
        expect("pulseDefault", "true", "step4 default pulses on streaming")

        # (5) transcribing → capture done → pulse off.
        write_state("transcribing")
        expect("pulseDefault", "false", "step5 no pulse while transcribing")

        # (6) daemon down (file removed) → pulse off.
        os.remove(state_file)
        expect("stateDefault", "down", "step6 removed")
        expect("pulseDefault", "false", "step6 no pulse when down")

        sys.stderr.write("PASS: bar-pulse activation contract holds\n")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
