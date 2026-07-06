#!/usr/bin/env python3
"""Component test for the NComboBox dropdown popup.

Regression guard for the model selector. The popup's height is
derived from its content ListView via
`Math.min(contentItem.implicitHeight, popupHeight)`. A bare ListView
reports implicitHeight 0, which collapses the Popup to zero height:
the dropdown "opens" but is invisible, so clicking the model selector
appears to do nothing. The content ListView MUST set
`implicitHeight: contentHeight` (matching Qt's own ComboBox popup) so
the popup gets a real height.

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

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:combo")
    qs.start()

    ipc = qs.ipc
    die = qs.die

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # Model wired up: 3 items, currentKey preselects "two".
        count = ipc("count")
        if count != "3":
            die(f"combo did not load the 3-item model (count={count})")

        # Popup starts hidden.
        if ipc("popupVisible") != "false":
            die("popup should start hidden")

        # Open the dropdown.
        ipc("openPopup")
        if not wait_until(
            lambda: ipc("popupVisible") == "true",
            timeout_s=5,
        ):
            die("popup never became visible after open()")

        # THE REGRESSION: an opened popup must have a real height. A
        # bare-ListView contentItem yields implicitHeight 0, so the
        # dropdown is invisible even though it reports "visible".
        def has_height():
            try:
                return float(ipc("popupHeight")) > 0
            except ValueError:
                return False

        if not wait_until(has_height, timeout_s=5):
            ch = ipc("contentHeight")
            ih = ipc("popupImplicitHeight")
            die(
                f"opened popup has zero height (implicitHeight={ih}, "
                f"contentHeight={ch}) — dropdown invisible"
            )

        sys.stderr.write("PASS: combo popup opens with non-zero height\n")
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
