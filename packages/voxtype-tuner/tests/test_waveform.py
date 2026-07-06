"""Take-waveform math: WAV bytes down to a fixed bar array for the take card.

Two layers, both driven without an audio device (this host has none):

- the pure downsampling math (:func:`bins_from_samples`): fed synthetic float
  buffers (silence, full scale, a ramp, a spike) to lock the bin count, the
  0..1 normalization, the silence floor, and the "louder reads taller" property.
- the file-level reader (:func:`analyze_take`): driven by real PCM16 WAVs
  written with libsndfile (the recorder's own format), plus the bundled sample
  when the environment wires one in, so the whole path from disk to bars is
  covered without mocking soundfile.
"""

from __future__ import annotations

import os
import pathlib
from typing import Any

import numpy as np
import numpy.typing as npt
import pytest
import soundfile as sf
from voxtype_tuner.waveform import (
    BIN_COUNT,
    TakeWaveform,
    analyze_take,
    bins_from_samples,
)

# --- pure math: bins_from_samples ---------------------------------------------


def test_silence_maps_to_a_flat_small_floor() -> None:
    # A silent take is still a take: every bar drops to the same small floor
    # rather than a zero-height (invisible) row or a crash.
    bins = bins_from_samples(np.zeros(16000, dtype=np.float32))
    assert len(bins) == BIN_COUNT
    assert all(0.0 <= b <= 1.0 for b in bins)
    assert all(b == pytest.approx(bins[0]) for b in bins)
    assert 0.0 < bins[0] < 0.2


def test_full_scale_normalizes_to_one() -> None:
    # A constant full-scale block peaks at 1 in every bin, so the tallest bar
    # fills the row exactly (relative normalization, not absolute dBFS).
    bins = bins_from_samples(np.ones(16000, dtype=np.float32))
    assert len(bins) == BIN_COUNT
    assert max(bins) == pytest.approx(1.0)


def test_a_ramp_reads_louder_toward_the_end() -> None:
    # A 0->1 amplitude ramp must read quiet at the start and tall at the end,
    # the core "louder is taller" contract the take card renders.
    bins = bins_from_samples(np.linspace(0.0, 1.0, 16000, dtype=np.float32))
    assert len(bins) == BIN_COUNT
    assert all(0.0 <= b <= 1.0 for b in bins)
    assert bins[-1] > bins[0]
    assert sum(bins[BIN_COUNT // 2 :]) > sum(bins[: BIN_COUNT // 2])


def test_empty_samples_yield_no_bars() -> None:
    # No audio at all clears the row (an empty model), never a NaN or a crash.
    assert bins_from_samples(np.zeros(0, dtype=np.float32)) == []


def test_a_lone_spike_stays_in_range_and_finite() -> None:
    # An out-of-range spike (clipping, a bad frame) must still normalize into
    # [0, 1] with no NaN reaching the renderer.
    sig = np.zeros(16000, dtype=np.float32)
    sig[100] = 5.0
    bins = bins_from_samples(sig)
    assert all(np.isfinite(b) for b in bins)
    assert all(0.0 <= b <= 1.0 for b in bins)
    assert max(bins) == pytest.approx(1.0)


def test_a_short_take_still_yields_the_full_bar_count() -> None:
    # Fewer samples than bins must not raise on the empty split chunks: the row
    # keeps its fixed width so it never reflows the card.
    bins = bins_from_samples(np.ones(10, dtype=np.float32))
    assert len(bins) == BIN_COUNT
    assert all(0.0 <= b <= 1.0 for b in bins)


# --- file-level reader: analyze_take ------------------------------------------


def _write_wav(path: pathlib.Path, data: npt.NDArray[Any], rate: int = 16000) -> None:
    sf.write(str(path), data, rate, subtype="PCM_16")


def test_analyze_take_of_an_absent_file_is_empty() -> None:
    got = analyze_take(str(pathlib.Path("/nonexistent/take.wav")))
    assert got == TakeWaveform([], "", "")


def test_analyze_take_reads_a_recorded_clip(tmp_path: pathlib.Path) -> None:
    # A realistic ~2s decaying-sine take, mono 16 kHz PCM16 (the recorder's own
    # format): the envelope decays, so early bins read louder than the tail.
    t = np.linspace(0.0, 2.0, 32000, endpoint=False)
    clip = (0.8 * np.exp(-t) * np.sin(2 * np.pi * 180.0 * t)).astype(np.float32)
    path = tmp_path / "take.wav"
    _write_wav(path, clip)

    got = analyze_take(str(path))
    assert len(got.bins) == BIN_COUNT
    assert all(0.0 <= b <= 1.0 for b in got.bins)
    assert got.bins[0] > got.bins[-1]
    assert got.duration == "0:02"
    assert got.meta == "16 kHz · mono"


def test_analyze_take_floors_a_silent_clip(tmp_path: pathlib.Path) -> None:
    path = tmp_path / "silent.wav"
    _write_wav(path, np.zeros(16000, dtype=np.float32))

    got = analyze_take(str(path))
    assert len(got.bins) == BIN_COUNT
    assert 0.0 < got.bins[0] < 0.2
    assert got.duration == "0:01"


def test_analyze_take_averages_stereo_to_mono(tmp_path: pathlib.Path) -> None:
    # A stereo file collapses to a mono envelope without crashing, and the meta
    # caption reports the real channel count.
    stereo = np.full((16000, 2), 0.6, dtype=np.float32)
    path = tmp_path / "stereo.wav"
    _write_wav(path, stereo)

    got = analyze_take(str(path))
    assert len(got.bins) == BIN_COUNT
    assert max(got.bins) == pytest.approx(1.0)
    assert got.meta == "16 kHz · stereo"


def test_analyze_take_formats_minutes_in_the_duration(tmp_path: pathlib.Path) -> None:
    # 65 seconds reads as 1:05, so a long take never overflows the M:SS slot.
    path = tmp_path / "long.wav"
    _write_wav(path, np.zeros(65 * 16000, dtype=np.float32))

    assert analyze_take(str(path)).duration == "1:05"


_SAMPLE = os.environ.get("VOXTYPE_TUNER_SAMPLE_WAV")


@pytest.mark.skipif(
    not (_SAMPLE and pathlib.Path(_SAMPLE).is_file()),
    reason="no bundled sample wired into the environment",
)
def test_analyze_take_on_the_bundled_sample() -> None:
    # The real jfk.wav the wrapper seeds: 16 kHz mono, normalized into [0, 1].
    got = analyze_take(str(_SAMPLE))
    assert len(got.bins) == BIN_COUNT
    assert all(0.0 <= b <= 1.0 for b in got.bins)
    assert max(got.bins) == pytest.approx(1.0)
    assert got.meta == "16 kHz · mono"
