"""Terminal-lifecycle tests: the pure signal/stdin logic everywhere, plus real
subprocess regressions (SIGINT, pty stdin EOF) where the headless backend is
available.

The subprocess tests spawn the actual app. The headless backend lives only in
the ``slint-dev`` wheel (the dev venv). The nix sandbox builds against the base
wheel where it fails outright, so those tests skip there. The extracted pure
logic in ``voxtype_tuner.lifecycle`` is what the sandbox covers.
"""

from __future__ import annotations

import importlib.util
import io
import os
import pty
import signal
import subprocess
import sys
import threading
from typing import TYPE_CHECKING

import pytest
from voxtype_tuner import lifecycle

if TYPE_CHECKING:
    from pathlib import Path


class _TtyPipeReader:
    """A pipe reader that claims to be a tty, so the watcher gate accepts it."""

    def __init__(self, fd: int) -> None:
        self._reader = os.fdopen(fd, "r")

    def isatty(self) -> bool:
        return True

    def readline(self) -> str:
        return self._reader.readline()


def test_watcher_not_installed_for_non_tty_stdin() -> None:
    # The desktop-launch guard: /dev/null or a closed stdin is not a terminal,
    # and hooking it would quit the app the instant the watcher reads EOF.
    assert lifecycle.watch_stdin_eof(io.StringIO(), lambda: None) is None


def test_watcher_fires_on_eof_and_ignores_ordinary_lines() -> None:
    read_fd, write_fd = os.pipe()
    stream = _TtyPipeReader(read_fd)
    fired = threading.Event()

    thread = lifecycle.watch_stdin_eof(stream, fired.set)
    assert thread is not None

    os.write(write_fd, b"typed text is not a quit request\n")
    assert not fired.wait(0.2)

    os.close(write_fd)  # Ctrl-D: the terminal reads as EOF
    assert fired.wait(5.0)
    thread.join(5.0)
    assert not thread.is_alive()


def test_watcher_treats_readline_oserror_as_eof() -> None:
    # A closed pty master surfaces as EIO on the slave, not a clean "" EOF.
    class ExplodingStream:
        def isatty(self) -> bool:
            return True

        def readline(self) -> str:
            raise OSError(5, "Input/output error")

    fired = threading.Event()
    thread = lifecycle.watch_stdin_eof(ExplodingStream(), fired.set)
    assert thread is not None
    assert fired.wait(5.0)


def test_install_signal_quit_routes_signal_to_quit_fn() -> None:
    # SIGUSR1 stands in for SIGINT/SIGTERM so the test cannot kill the runner.
    calls: list[int] = []
    previous = signal.getsignal(signal.SIGUSR1)
    try:
        lifecycle.install_signal_quit(
            lambda: calls.append(1), signums=(signal.SIGUSR1,)
        )
        os.kill(os.getpid(), signal.SIGUSR1)
        assert calls == [1]
    finally:
        signal.signal(signal.SIGUSR1, previous)


_HAVE_HEADLESS = importlib.util.find_spec("slint_dev_native") is not None

needs_headless = pytest.mark.skipif(
    not _HAVE_HEADLESS,
    reason="headless backend requires the slint-dev wheel (dev venv only, since "
    "the nix sandbox ships the base wheel where SLINT_BACKEND=headless fails)",
)

_READY_LINE = "entering event loop"


def _spawn_app(tmp_path: Path, stdin: int) -> subprocess.Popen[str]:
    env = os.environ.copy()
    env.update(
        {
            # Full isolation: never touch the host's configs/recordings.
            "XDG_DATA_HOME": str(tmp_path / "data"),
            "XDG_CONFIG_HOME": str(tmp_path / "config"),
            "VOXTYPE_TUNER_DEFAULT_CONFIG": str(tmp_path / "absent.toml"),
            # Render without a display. Any SLINT_MCP_PORT value at import
            # time makes slint load the headless-capable dev binary, and 0
            # binds an ephemeral port (a bind failure is non-fatal anyway).
            "SLINT_BACKEND": "headless",
            "SLINT_MCP_PORT": "0",
        }
    )
    env.pop("VOXTYPE_TUNER_SAMPLE_WAV", None)
    return subprocess.Popen(
        [sys.executable, "-m", "voxtype_tuner.app"],
        stdin=stdin,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
    )


def _wait_for_ready(proc: subprocess.Popen[str], timeout: float = 60.0) -> None:
    """Block until the app logs its ready line (signal handlers installed)."""
    ready = threading.Event()
    lines: list[str] = []

    def read() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            lines.append(line)
            if _READY_LINE in line:
                ready.set()
        # Keep draining so the app can never block on a full stderr pipe.

    threading.Thread(target=read, daemon=True).start()
    if not ready.wait(timeout):
        proc.kill()
        msg = f"app never became ready, stderr so far: {lines!r}"
        raise AssertionError(msg)


@needs_headless
def test_sigint_exits_cleanly(tmp_path: Path) -> None:
    # Ctrl-C in the launching terminal: the Slint loop runs in native code and
    # never yields to the interpreter on its own, so this exercises the whole
    # chain: wake-up timer, Python signal delivery, quit_event_loop.
    proc = _spawn_app(tmp_path, stdin=subprocess.DEVNULL)
    try:
        _wait_for_ready(proc)
        proc.send_signal(signal.SIGINT)
        assert proc.wait(timeout=15) == 0
    finally:
        if proc.poll() is None:
            proc.kill()


@needs_headless
def test_sigterm_exits_cleanly(tmp_path: Path) -> None:
    proc = _spawn_app(tmp_path, stdin=subprocess.DEVNULL)
    try:
        _wait_for_ready(proc)
        proc.terminate()
        assert proc.wait(timeout=15) == 0
    finally:
        if proc.poll() is None:
            proc.kill()


@needs_headless
def test_stdin_eof_exits_cleanly(tmp_path: Path) -> None:
    # Ctrl-D: the app gets a real pty as stdin (so the isatty gate accepts it).
    # Closing the master is what the terminal's EOF/teardown looks like.
    master, slave = pty.openpty()
    proc = _spawn_app(tmp_path, stdin=slave)
    os.close(slave)
    try:
        _wait_for_ready(proc)
        os.close(master)
        assert proc.wait(timeout=15) == 0
    finally:
        if proc.poll() is None:
            proc.kill()


@needs_headless
def test_dev_null_stdin_does_not_insta_quit(tmp_path: Path) -> None:
    # The gate itself, end to end: a desktop-style launch (stdin not a tty)
    # must keep running despite stdin being at EOF from the start.
    proc = _spawn_app(tmp_path, stdin=subprocess.DEVNULL)
    try:
        _wait_for_ready(proc)
        with pytest.raises(subprocess.TimeoutExpired):
            proc.wait(timeout=2)
    finally:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=15)
        finally:
            if proc.poll() is None:
                proc.kill()
