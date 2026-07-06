"""Recorder tests driven by a fake InputStream, no real audio device required.

``FakeInputStream`` captures the kwargs the recorder opens the stream with and
exposes the capture callback, so a test can feed synthetic frames exactly as
PortAudio would. The recorder then writes a real WAV via libsndfile, which we
read back to lock the 16 kHz / mono / 16-bit target format.
"""

from pathlib import Path
from typing import Any, ClassVar

import numpy as np
import pytest
import sounddevice as sd
import soundfile as sf
from voxtype_tuner.recorder import Recorder, RecorderError, start_recording


class FakeInputStream:
    """Stand-in for ``sd.InputStream`` that records how it was opened."""

    instances: ClassVar[list["FakeInputStream"]] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.callback = kwargs["callback"]
        self.started = False
        self.stopped = False
        self.closed = False
        FakeInputStream.instances.append(self)

    def start(self) -> None:
        self.started = True

    def stop(self) -> None:
        self.stopped = True

    def close(self) -> None:
        self.closed = True


@pytest.fixture(autouse=True)
def _clear_instances() -> Any:
    FakeInputStream.instances.clear()
    yield
    FakeInputStream.instances.clear()


def _sine_int16(samplerate: int = 16000, seconds: float = 0.1) -> Any:
    t = np.linspace(0.0, seconds, int(samplerate * seconds), endpoint=False)
    samples = 0.5 * np.sin(2 * np.pi * 440.0 * t)
    return (samples * 32767).astype(np.int16).reshape(-1, 1)


def test_start_recording_opens_stream_at_16k_mono(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    rec = start_recording("/tmp/unused.wav")
    assert isinstance(rec, Recorder)
    stream = FakeInputStream.instances[-1]
    assert stream.kwargs["samplerate"] == 16000
    assert stream.kwargs["channels"] == 1
    assert stream.started is True


def test_start_recording_defaults_device_to_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    start_recording("/tmp/unused.wav")
    stream = FakeInputStream.instances[-1]
    # No selection opens PortAudio's own default input.
    assert stream.kwargs["device"] is None


def test_start_recording_opens_the_requested_device_index(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    start_recording("/tmp/unused.wav", device=5)
    stream = FakeInputStream.instances[-1]
    # The picker's PortAudio index reaches the capture stream verbatim.
    assert stream.kwargs["device"] == 5


def test_stop_writes_16k_mono_pcm16_wav(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    wav_path = str(tmp_path / "capture.wav")
    rec = start_recording(wav_path)
    stream = FakeInputStream.instances[-1]

    block = _sine_int16()
    stream.callback(block, len(block), None, None)
    stream.callback(block, len(block), None, None)

    rec.stop()

    assert stream.stopped is True
    assert stream.closed is True

    info = sf.info(wav_path)
    assert info.samplerate == 16000
    assert info.channels == 1
    assert info.subtype == "PCM_16"

    data, samplerate = sf.read(wav_path, dtype="int16")
    assert samplerate == 16000
    assert data.ndim == 1  # mono reads back one-dimensional
    assert len(data) == 2 * len(block)


def test_start_recording_no_device_raises_recorder_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _boom(**_kwargs: Any) -> None:
        msg = "no default input device"
        raise sd.PortAudioError(msg)

    monkeypatch.setattr(sd, "InputStream", _boom)
    with pytest.raises(RecorderError) as excinfo:
        start_recording("/tmp/unused.wav")
    assert str(excinfo.value)  # UI-displayable, non-empty message


def test_soundfile_roundtrip_locks_target_format(tmp_path: Path) -> None:
    """Real libsndfile path: a 16k mono PCM_16 WAV round-trips faithfully."""
    wav_path = str(tmp_path / "sine.wav")
    block = _sine_int16()
    sf.write(wav_path, block, 16000, subtype="PCM_16")

    data, samplerate = sf.read(wav_path, dtype="int16")
    assert samplerate == 16000
    assert data.ndim == 1
    info = sf.info(wav_path)
    assert info.channels == 1
    assert info.subtype == "PCM_16"
