"""File-descriptor-level stderr suppression for the PortAudio/ALSA C probes.

sounddevice's device enumeration and stream open call into PortAudio, which
probes ALSA in C and writes its warnings (the "Expression 'r' failed in
'src/hostapi/alsa/pa_linux_alsa.c'" family, "cannot open ... default", ...)
straight to file descriptor 2. Python's ``contextlib.redirect_stderr`` only
rebinds the ``sys.stderr`` object, so it never catches those C-level writes.
Only duplicating ``/dev/null`` over the raw fd does.

Kept deliberately narrow: wrap ONLY the unavoidable sounddevice probe/open call,
never a wider block that could raise a real Python exception, so a genuine
traceback is never swallowed along with the ALSA chatter.
"""

from __future__ import annotations

import contextlib
import os
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator


@contextlib.contextmanager
def suppress_c_stderr() -> Iterator[None]:
    """Silence file descriptor 2 for the duration of the block.

    Flush Python's own stderr first so no buffered line is lost across the
    swap, duplicate the real fd so it can be restored, point fd 2 at
    ``/dev/null``, and restore it in ``finally`` even when the wrapped call
    raises. See the module docstring for why this is fd-level and not a
    ``sys.stderr`` rebind.
    """
    sys.stderr.flush()
    saved = os.dup(2)
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 2)
        yield
    finally:
        os.dup2(saved, 2)
        os.close(saved)
        os.close(devnull)
