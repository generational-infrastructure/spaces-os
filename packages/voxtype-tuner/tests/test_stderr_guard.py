"""Tests for the fd-level stderr suppressor.

The PortAudio/ALSA C probes write straight to file descriptor 2, so the guard
must silence the raw fd (not just Python's ``sys.stderr`` object) and restore it
afterwards. Point the real fd 2 at a file we own, exercise the guard, and read
that file back: what is written inside the block must be swallowed, and normal
stderr must work again once the block exits.
"""

from __future__ import annotations

import os
from typing import TYPE_CHECKING

import pytest
from voxtype_tuner.stderr_guard import suppress_c_stderr

if TYPE_CHECKING:
    import pathlib


def _raise_boom() -> None:
    msg = "boom"
    raise ValueError(msg)


def test_suppress_c_stderr_swallows_fd2_writes_then_restores(
    tmp_path: pathlib.Path,
) -> None:
    log = tmp_path / "stderr.log"
    # Redirect the real fd 2 at our own file so we can observe exactly what
    # reaches it, independent of pytest's own capture. Save and restore it.
    saved = os.dup(2)
    sink = os.open(str(log), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    try:
        os.dup2(sink, 2)
        os.close(sink)

        with suppress_c_stderr():
            os.write(2, b"swallowed-inside\n")  # goes to /dev/null

        os.write(2, b"restored-after\n")  # our file again
    finally:
        os.dup2(saved, 2)
        os.close(saved)

    contents = log.read_text()
    assert "swallowed-inside" not in contents
    assert "restored-after" in contents


def test_suppress_c_stderr_restores_even_when_the_body_raises(
    tmp_path: pathlib.Path,
) -> None:
    # A real Python exception inside the guarded block must propagate AND fd 2
    # must still be restored, so a genuine traceback is never swallowed.
    log = tmp_path / "stderr.log"
    saved = os.dup(2)
    sink = os.open(str(log), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    try:
        os.dup2(sink, 2)
        os.close(sink)

        with pytest.raises(ValueError, match="boom"), suppress_c_stderr():
            _raise_boom()

        os.write(2, b"restored-after-raise\n")
    finally:
        os.dup2(saved, 2)
        os.close(saved)

    assert "restored-after-raise" in log.read_text()
