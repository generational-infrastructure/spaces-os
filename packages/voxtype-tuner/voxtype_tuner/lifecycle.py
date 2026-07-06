"""Terminal lifecycle: quit the UI cleanly on Ctrl-C/SIGTERM and Ctrl-D.

Pure logic (no ``slint`` import) so it unit-tests in the nix sandbox, while app.py
composes these with the Slint pieces. Two facts about slint-python 1.17 shape
this module (verified empirically against the pinned wheel):

- The native event loop runs no Python bytecode while idle, so CPython never
  gets a chance to deliver a pending SIGINT. The handler installed here only
  fires if the app also runs a periodic no-op ``slint.Timer`` as a wake-up.
- ``slint.quit_event_loop()`` is only safe on the loop thread. A signal
  handler runs there (the main thread IS the loop thread), so it may call the
  quit function directly. The stdin watcher thread must not, so its ``on_eof``
  is expected to marshal via ``invoke_from_event_loop``.
"""

from __future__ import annotations

import signal
import threading
from typing import TYPE_CHECKING, Any, Protocol

if TYPE_CHECKING:
    from collections.abc import Callable


class _Readable(Protocol):
    def isatty(self) -> bool: ...

    def readline(self) -> str: ...


def install_signal_quit(
    quit_fn: Callable[[], None],
    signums: tuple[signal.Signals, ...] = (signal.SIGINT, signal.SIGTERM),
) -> None:
    """Quit the event loop (instead of raising) on ``signums``.

    Raising KeyboardInterrupt from the handler does NOT work here: the
    exception surfaces inside a pyo3 timer-callback trampoline that prints and
    swallows it, so it never propagates out of ``Component.run()``. Calling
    the quit function synchronously does work and returns the loop cleanly.
    """

    def handler(_signum: int, _frame: Any) -> None:
        quit_fn()

    for signum in signums:
        signal.signal(signum, handler)


def watch_stdin_eof(
    stream: _Readable, on_eof: Callable[[], None]
) -> threading.Thread | None:
    """Fire ``on_eof`` from a daemon thread when ``stream`` reaches EOF.

    Gated on ``isatty``: a desktop launch with a closed or /dev/null stdin
    reads EOF immediately and must NOT quit the app. Only an interactive
    terminal's Ctrl-D means "the user closed the session". Returns the watcher
    thread, or ``None`` when the gate declined to install one.
    """
    try:
        if not stream.isatty():
            return None
    except (AttributeError, ValueError, OSError):
        return None

    def watch() -> None:
        try:
            while stream.readline():
                pass
        except (OSError, ValueError):
            # A closed pty master delivers EIO on read rather than a clean ""
            # EOF (and a closed file object raises ValueError). Both mean the
            # terminal is gone.
            pass
        on_eof()

    thread = threading.Thread(target=watch, daemon=True, name="stdin-eof-watch")
    thread.start()
    return thread
