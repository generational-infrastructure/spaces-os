"""Tests for the latency/RTFx metrics helpers.

The definitions are ported from the predecessor repo's Rust A/B harness so the
tuner's numbers stay comparable with it: latency is the measured wall-clock of
the processing span, ``rtfx = audio_secs / processing_secs`` (0.0 whenever
either side is unknown), and the audio length comes from the WAV header, never
from anything voxtype reports.
"""

import wave
from pathlib import Path

from voxtype_tuner.metrics import (
    batch_caption,
    format_timing,
    rtfx,
    streaming_caption,
    wav_duration_secs,
)


def _write_wav(path: Path, frames: int, samplerate: int = 16000) -> None:
    with wave.open(str(path), "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(samplerate)
        fh.writeframes(b"\x00\x00" * frames)


def test_wav_duration_reads_the_header(tmp_path: Path) -> None:
    wav = tmp_path / "take.wav"
    _write_wav(wav, frames=8000)  # 0.5s at 16 kHz
    assert wav_duration_secs(str(wav)) == 0.5


def test_wav_duration_unreadable_is_zero(tmp_path: Path) -> None:
    # Mirrors the harness: "0.0 if it could not be read". A missing take or
    # garbage bytes must degrade the RTFx to absent, never raise into the UI.
    assert wav_duration_secs(str(tmp_path / "missing.wav")) == 0.0
    garbage = tmp_path / "garbage.wav"
    garbage.write_bytes(b"not a riff header")
    assert wav_duration_secs(str(garbage)) == 0.0


def test_rtfx_is_audio_over_processing() -> None:
    assert rtfx(audio_secs=11.0, processing_secs=1.0) == 11.0
    assert rtfx(audio_secs=2.0, processing_secs=4.0) == 0.5


def test_rtfx_unknown_sides_read_zero() -> None:
    # ">1 means faster than real time, 0.0 when processing time or audio
    # length is unknown". The caption drops the ratio instead of showing inf.
    assert rtfx(audio_secs=0.0, processing_secs=1.0) == 0.0
    assert rtfx(audio_secs=1.0, processing_secs=0.0) == 0.0
    assert rtfx(audio_secs=-1.0, processing_secs=1.0) == 0.0


def test_format_timing_seconds_one_decimal() -> None:
    assert format_timing(0.9) == "0.9s"
    assert format_timing(12.34) == "12.3s"
    assert format_timing(0.1) == "0.1s"


def test_format_timing_sub_100ms_shows_milliseconds() -> None:
    assert format_timing(0.045) == "45ms"
    assert format_timing(0.009) == "9ms"
    assert format_timing(0.0) == "0ms"
    assert format_timing(0.0999) == "100ms"


def test_batch_caption_carries_latency_and_rtfx() -> None:
    assert batch_caption(processing_s=0.9, audio_secs=11.0) == (
        "Transcribed in 0.9s · 12.2x realtime"
    )


def test_batch_caption_without_audio_length_drops_rtfx() -> None:
    # An unreadable take (or a stub in tests) has no audio length. The caption
    # must degrade to the plain latency rather than claim a fake ratio.
    assert batch_caption(processing_s=0.9, audio_secs=0.0) == "Transcribed in 0.9s"


def test_streaming_caption_session_and_finalize() -> None:
    # The two honest streaming wall-clocks, both from observed daemon state
    # transitions: session length (record start → stop request) and the
    # finalize wait (stop request → the daemon's idle). No RTFx: a live
    # stream is gated on real-time audio, so the ratio would be a fake
    # benchmark, and no first-partial: no partial timestamps exist anywhere.
    assert (
        streaming_caption(session_s=5.6, finalize_s=0.4, hit_max_duration=False)
        == "Streamed 5.6s · finalized in 0.4s"
    )


def test_streaming_caption_reached_max_duration() -> None:
    # A session the daemon ended itself at the configured cap must say so,
    # a distinct state, not a fabricated finalize wait.
    assert (
        streaming_caption(session_s=60.2, finalize_s=None, hit_max_duration=True)
        == "Streamed 60.2s · reached max duration"
    )


def test_streaming_caption_daemon_ended_early_keeps_only_session() -> None:
    # Ended by the daemon before the cap (and with no stop request there is
    # no stop→idle measurement): only the session length is honest.
    assert (
        streaming_caption(session_s=3.0, finalize_s=None, hit_max_duration=False)
        == "Streamed 3.0s"
    )
