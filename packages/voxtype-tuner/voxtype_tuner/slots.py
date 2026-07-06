"""Single-take WAV persistence under the XDG data directory.

Kept separate from capture so path/state logic carries no PortAudio dependency:
the app composes :func:`take_wav_path` with the recorder/player primitives to
persist the take across runs, so it can be re-transcribed with different params
without re-recording.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

_APP_SUBDIR = "voxtype-tuner"
_TAKE_FILENAME = "take.wav"


def _data_home() -> str:
    # Empty XDG_DATA_HOME is as good as unset. Fall back to the spec default.
    return os.environ.get("XDG_DATA_HOME") or str(Path("~/.local/share").expanduser())


def take_wav_path() -> str:
    """Return the stable WAV path for the recording take, creating its dir."""
    directory = Path(_data_home()) / _APP_SUBDIR
    directory.mkdir(parents=True, exist_ok=True)
    return str(directory / _TAKE_FILENAME)


def take_has_recording() -> bool:
    """Return ``True`` iff the take has a persisted WAV on disk."""
    return Path(take_wav_path()).exists()


def seed_take(sample_path: str | None) -> bool:
    """Pre-load ``sample_path`` as the take when none is recorded yet.

    So a fresh run is instantly transcribable/playable without recording first.
    A take that already holds a user recording is never touched, so this is safe
    to call on every startup. A ``None`` or missing ``sample_path`` (a bare
    checkout with no bundled asset wired in) is a graceful no-op. Returns
    whether the sample was copied in.
    """
    if not sample_path or not Path(sample_path).is_file():
        return False
    if take_has_recording():
        return False
    shutil.copyfile(sample_path, take_wav_path())
    return True
