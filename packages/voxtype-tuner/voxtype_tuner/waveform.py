"""Downsample a take WAV into a fixed bar array for the take-card waveform.

The take card draws the recorded take as a fixed row of vertical bars. This
module turns the take's PCM into the heights those bars read from, kept
slint-free (pure numpy over a soundfile read) so it unit-tests without the
native UI lib or an audio device.

Two layers:

- :func:`bins_from_samples`, the pure downsampler: one mono float buffer to a
  fixed count of peak-per-bin heights, normalized so the loudest bin fills the
  row (relative, not absolute dBFS). Silence settles on a small floor so the
  row still reads as a present-but-quiet take rather than a blank strip, and an
  absent buffer clears to no bars at all.
- :func:`analyze_take`, the file reader: the take WAV down to that bar array
  plus the ``M:SS`` duration and a ``16 kHz . mono`` format caption for the
  card's trailing meta. A missing or corrupt take degrades to the empty result,
  never a raised error into the UI (mirrors :func:`player.play`).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import numpy.typing as npt
import soundfile as sf

# The take card renders this many bars. Wide enough to read as a waveform,
# narrow enough that 3px bars with a 2px gap span the 360px left column.
BIN_COUNT = 36

# A silent or very quiet bin still shows this fraction of the row, so the bar
# row never collapses to an invisible line. About 3px of the 58px row.
_FLOOR = 0.06

# Below this peak the whole buffer counts as silence and every bar drops to the
# floor, so quantization noise near zero cannot fabricate a tall bar.
_SILENCE_EPS = 1e-6


def bins_from_samples(
    samples: npt.NDArray[np.floating], count: int = BIN_COUNT
) -> list[float]:
    """Peak-per-bin heights in ``[0, 1]`` for a mono float buffer.

    The buffer is split into ``count`` contiguous chunks and each chunk's
    absolute peak becomes one bar. Heights are normalized by the loudest chunk
    so the tallest bar fills the row, then clamped up to a small floor so a
    quiet bin stays visible. An empty buffer yields no bars, silence yields a
    flat floor row, and an out-of-range spike still normalizes into ``[0, 1]``
    with no NaN reaching the renderer.
    """
    flat = np.abs(np.asarray(samples, dtype=np.float64).reshape(-1))
    if flat.size == 0:
        return []

    peaks = np.array(
        [chunk.max() if chunk.size else 0.0 for chunk in np.array_split(flat, count)]
    )
    loudest = float(peaks.max())
    if loudest < _SILENCE_EPS:
        return [_FLOOR] * count

    normalized = np.clip(peaks / loudest, 0.0, 1.0)
    return [max(float(value), _FLOOR) for value in normalized]


@dataclass(frozen=True)
class TakeWaveform:
    """The take card's derived view of the current take.

    ``bins`` are the bar heights (empty when there is no readable take),
    ``duration`` the ``M:SS`` length, and ``meta`` the ``16 kHz . mono`` format
    caption. The two strings are empty exactly when ``bins`` is, so the card can
    gate all three on one absent take.
    """

    bins: list[float]
    duration: str
    meta: str


_EMPTY = TakeWaveform([], "", "")


def _duration(frames: int, rate: int) -> str:
    seconds = round(frames / rate) if rate > 0 else 0
    minutes, secs = divmod(seconds, 60)
    return f"{minutes}:{secs:02d}"


def _khz(rate: int) -> str:
    # Whole rates read as "16 kHz", fractional ones keep one decimal ("44.1").
    khz = rate / 1000.0
    return f"{khz:g} kHz"


def _channels(count: int) -> str:
    if count == 1:
        return "mono"
    if count == 2:  # noqa: PLR2004
        return "stereo"
    return f"{count} ch"


def analyze_take(path: str, count: int = BIN_COUNT) -> TakeWaveform:
    """Read the take WAV into a :class:`TakeWaveform`, empty if unreadable.

    A missing take (nothing recorded, no seeded sample) or a corrupt file
    degrades to :data:`_EMPTY` rather than raising, so a bare host or a broken
    WAV shows a calm empty row instead of crashing the UI.
    """
    try:
        data, rate = sf.read(path, dtype="float32", always_2d=True)
    except (sf.LibsndfileError, OSError, RuntimeError):
        return _EMPTY

    frames, channels = data.shape
    if frames == 0 or rate <= 0:
        return _EMPTY

    mono = data.mean(axis=1)
    return TakeWaveform(
        bins=bins_from_samples(mono, count),
        duration=_duration(frames, rate),
        meta=f"{_khz(rate)} · {_channels(channels)}",
    )
