#!/usr/bin/env python3
"""Component test for Panel.qml's surface sizing.

Regression guard for the chat panel's width. shell.qml asks the
Quickshell PanelWindow for `implicitWidth: 480`. QQuickWindow takes
its implicit size from its contentItem, so any `implicitWidth` the
embedded Panel sets propagates upward and replaces the shell's 480.
Panel.qml used to carry a `contentPreferredWidth: 1000` left over
from the noctalia SmartPanel host and bind `implicitWidth` to it;
that forced the wayland surface to ~1000 px, which on a typical
laptop pushes the header buttons and every chat bubble off the
right edge of the screen.

Panel.qml MUST NOT propagate an implicit width larger than the
window it's embedded in.

Headless quickshell, offscreen platform. No compositor, no pi, no
LLM. ~3s.
"""

import os
import sys

from qs_harness import Quickshell, qs_env, stage_shell, wait_until


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir)

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:panel-width")
    qs.start()

    die = qs.die

    def ipc_call(*args: str, target: str = "test:panel-width") -> str:
        return qs.ipc(*args, target=target)

    try:

        def ipc_ready():
            return qs.ipc_ready("test:panel-width")

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test IPC targets")

        # Sanity: the window honoured shell.qml's implicitWidth of 480.
        # If this drifts the rest of the assertions become meaningless.
        win_implicit = ipc_call("winImplicitWidth")
        if win_implicit != "480":
            die(
                f"test harness window.implicitWidth={win_implicit}, expected 480 "
                "— shell.qml binding broken"
            )

        # THE REGRESSION: Panel.qml advertised implicitWidth = 1000
        # (the noctalia SmartPanel `contentPreferredWidth`), which the
        # QQuickWindow contentItem propagates to the wayland surface
        # request. On a typical-width screen the panel ends up wider
        # than the layer-shell output and content clips off the right
        # edge.
        try:
            implicit = float(ipc_call("panelImplicitWidth"))
        except ValueError as e:
            die(f"panelImplicitWidth IPC returned non-numeric value: {e}")

        if implicit > 480:
            die(
                f"Panel.implicitWidth={implicit:.0f}px, exceeds the host window's "
                "480px — surface will overflow the screen edge"
            )

        # Second-order check: the laid-out width must also fit, which
        # confirms that anchors.fill is doing its job once the implicit
        # is sane. Allow a small tolerance for window-frame rounding.
        try:
            laid = float(ipc_call("panelWidth"))
        except ValueError as e:
            die(f"panelWidth IPC returned non-numeric value: {e}")

        if laid > 480:
            die(
                f"Panel.width={laid:.0f}px, exceeds the 480px host window — "
                "anchors.fill not respected"
            )

        sys.stderr.write(
            f"PASS: panel implicitWidth={implicit:.0f} width={laid:.0f} (both <= 480)\n"
        )

    finally:
        qs.stop()


if __name__ == "__main__":
    main()
