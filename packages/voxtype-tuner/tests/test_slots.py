"""Persistence path/state tests for the single-take WAV storage.

XDG_DATA_HOME is redirected to a tmp dir so the tests never touch the real
~/.local/share, and to prove the parent directory is created on demand. No audio
device is involved here. This is pure path/state logic.
"""

import wave
from pathlib import Path

import pytest
from voxtype_tuner.slots import seed_take, take_has_recording, take_wav_path


def _write_wav(path: str, frames: bytes) -> None:
    """Write a minimal real 16 kHz mono 16-bit WAV so existence is meaningful."""
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(frames)


def _write_silent_wav(path: str) -> None:
    _write_wav(path, b"\x00\x00" * 160)


def test_take_wav_path_under_xdg_data_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    path = take_wav_path()
    assert path == str(tmp_path / "voxtype-tuner" / "take.wav")
    # The parent dir is created eagerly so a later write cannot fail on ENOENT.
    assert (tmp_path / "voxtype-tuner").is_dir()


def test_take_has_recording_false_until_file_written(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    assert take_has_recording() is False
    _write_silent_wav(take_wav_path())
    assert take_has_recording() is True


def test_seed_take_fills_an_empty_take(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    sample = tmp_path / "sample.wav"
    _write_silent_wav(str(sample))

    assert seed_take(str(sample)) is True

    assert take_has_recording()
    # A byte-for-byte copy of the sample, so the take is really transcribable.
    assert Path(take_wav_path()).read_bytes() == sample.read_bytes()


def test_seed_take_never_clobbers_a_recording(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    sample = tmp_path / "sample.wav"
    _write_silent_wav(str(sample))
    # The take already holds a user recording with distinct audio bytes.
    _write_wav(take_wav_path(), b"\x11\x22" * 320)
    recording = Path(take_wav_path()).read_bytes()

    assert seed_take(str(sample)) is False

    assert Path(take_wav_path()).read_bytes() == recording


def test_seed_take_is_noop_without_a_sample(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    # A bare checkout leaves VOXTYPE_TUNER_SAMPLE_WAV unset (-> None), and a
    # dangling path must not raise either. Both seed nothing.
    assert seed_take(None) is False
    assert seed_take(str(tmp_path / "missing.wav")) is False
    assert not take_has_recording()
