"""Put text on the system clipboard by shelling out to a Wayland clipboard tool.

slint-python exposes no clipboard setter of its own. The ``.slint``
``TextInput.copy()`` only ever copies the widget's current selection through the
running backend, which the headless test backend lacks and no test can point at
a fake, so it fails this package's inject-a-fake testability bar. The transcript
is instead written through ``wl-copy`` from wl-clipboard, whose binary is
injectable (``WL_COPY_BIN``) exactly like ``VOXTYPE_BIN``. The packaged wrapper
puts wl-clipboard on PATH. A bare checkout without it degrades to a worded
failure rather than a crash.
"""

from __future__ import annotations

import subprocess


def copy_text(text: str, *, wl_copy_bin: str = "wl-copy", timeout: float = 5.0) -> bool:
    """Place ``text`` on the system clipboard via ``wl-copy``. Never raises.

    The text is fed on stdin so it is copied verbatim (no argv length limit, no
    dash-prefixed transcript read as an option). Returns True when the tool
    accepted it, False on any failure (the binary missing, a non-zero exit, a
    timeout), so the caller words the outcome instead of the UI thread catching
    an exception.
    """
    try:
        result = subprocess.run(
            [wl_copy_bin],
            input=text,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0
