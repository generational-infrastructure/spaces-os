"""Latency and RTFx metrics for the batch and streaming transcription paths.

The definitions are ported from the predecessor repo's Rust A/B harness so this
tuner's numbers stay comparable with it:

- latency is measured wall-clock around the processing span, never a timing
  voxtype logs itself.
- ``rtfx = audio_secs / processing_secs`` (>1 is faster than real time), 0.0
  whenever either side is unknown, and the caption then drops the ratio
  instead of showing a fake one.
- ``audio_secs`` comes from the take's WAV header, 0.0 if unreadable.

The RTFx exists for the BATCH path only. A streaming session is gated on
real-time audio (capture and processing overlap), so a ratio would read ≈1 by
construction, a fake benchmark. Streaming gets exactly the wall-clocks its
observable daemon state transitions support: session length and the
stop→idle finalize wait. No first-partial number exists anywhere to report.
"""

from __future__ import annotations

import contextlib
import wave

# Below this threshold the timing label reads better as whole milliseconds.
_MS_DISPLAY_CUTOFF_S = 0.1


def format_timing(elapsed_s: float) -> str:
    """Human-friendly wall-clock for the timing captions.

    Sub-100ms spans read better as whole milliseconds ("45ms"), anything longer
    as seconds with one decimal ("0.9s", "12.3s").
    """
    if elapsed_s < _MS_DISPLAY_CUTOFF_S:
        return f"{round(elapsed_s * 1000)}ms"
    return f"{elapsed_s:.1f}s"


def wav_duration_secs(path: str) -> float:
    """The take's audio length from its WAV header, 0.0 if unreadable.

    Mirrors the harness contract: a missing or corrupt file degrades the RTFx
    to absent (the caption drops the ratio), it never raises into the UI. The
    stdlib parser is enough, since every take here is libsndfile-written PCM16.
    """
    with (
        contextlib.suppress(OSError, wave.Error, EOFError),
        wave.open(path, "rb") as fh,
    ):
        rate = fh.getframerate()
        if rate > 0:
            return fh.getnframes() / rate
    return 0.0


def rtfx(audio_secs: float, processing_secs: float) -> float:
    """Real-time factor: ``audio_secs / processing_secs``, 0.0 when unknown."""
    if audio_secs <= 0.0 or processing_secs <= 0.0:
        return 0.0
    return audio_secs / processing_secs


def _with_rtfx(base: str, audio_secs: float, processing_s: float) -> str:
    ratio = rtfx(audio_secs, processing_s)
    if ratio <= 0.0:
        return base
    return f"{base} · {ratio:.1f}x realtime"


def batch_caption(processing_s: float, audio_secs: float) -> str:
    """The timing caption for a completed one-shot transcribe."""
    return _with_rtfx(
        f"Transcribed in {format_timing(processing_s)}", audio_secs, processing_s
    )


def streaming_caption(
    session_s: float,
    finalize_s: float | None,
    hit_max_duration: bool,
) -> str:
    """The timing caption for a completed streaming session.

    ``session_s`` is the streaming span (record start → stop request).
    ``finalize_s`` is the stop→idle wait, ``None`` when the daemon ended the
    session itself (nothing was measured). A session the daemon cut at the
    configured cap says "reached max duration", a distinct state, never a
    fabricated finalize number.
    """
    base = f"Streamed {format_timing(session_s)}"
    if hit_max_duration:
        return f"{base} · reached max duration"
    if finalize_s is not None:
        return f"{base} · finalized in {format_timing(finalize_s)}"
    return base
