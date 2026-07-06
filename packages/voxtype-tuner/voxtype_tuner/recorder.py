"""Microphone capture to a 16 kHz mono 16-bit PCM WAV.

Capture runs on PortAudio's own callback thread via an ``sd.InputStream``.
:func:`start_recording` returns immediately with a live :class:`Recorder`, and
:meth:`Recorder.stop` halts the stream before writing the accumulated frames to
the target WAV with libsndfile. A missing input device (common on headless or
CI hosts) surfaces as a :class:`RecorderError` whose message is safe to show in
the UI, so the caller never faces a bare PortAudio crash.
"""

from __future__ import annotations

from typing import Any

import numpy as np
import numpy.typing as npt
import sounddevice as sd
import soundfile as sf

# Capture the engine-ready target directly: 16-bit samples handed straight to
# libsndfile's PCM_16 writer, no lossy float round-trip.
_DTYPE = "int16"


class RecorderError(Exception):
    """Raised when capture cannot start/finish (e.g. no input device).

    The message is safe to surface in the UI.
    """


class Recorder:
    """A live capture handle. Call :meth:`stop` to finalize the WAV."""

    def __init__(
        self,
        wav_path: str,
        stream: Any,
        frames: list[npt.NDArray[np.int16]],
        samplerate: int,
        channels: int,
    ) -> None:
        self._wav_path = wav_path
        self._stream = stream
        self._frames = frames
        self._samplerate = samplerate
        self._channels = channels
        self._finalized = False

    def stop(self) -> None:
        """Stop capture, then write the accumulated frames to ``wav_path``."""
        if self._finalized:
            return
        self._finalized = True
        try:
            self._stream.stop()
            self._stream.close()
        except sd.PortAudioError as exc:
            msg = f"could not finish audio capture: {exc}"
            raise RecorderError(msg) from exc

        if self._frames:
            data = np.concatenate(self._frames, axis=0)
        else:
            data = np.zeros((0, self._channels), dtype=np.int16)
        sf.write(self._wav_path, data, self._samplerate, subtype="PCM_16")


def start_recording(
    wav_path: str,
    device: int | None = None,
    samplerate: int = 16000,
    channels: int = 1,
) -> Recorder:
    """Open an input device and start capturing in the background.

    ``device`` is the PortAudio device INDEX to capture from (the tuner's device
    picker threads it through). ``None`` opens PortAudio's own default input, so
    a host with no selection or no picker still records. Returns immediately
    with a live :class:`Recorder`. Raises :class:`RecorderError` (never a bare
    PortAudio error) when the device cannot be opened, so the UI can show the
    message instead of crashing.
    """
    frames: list[npt.NDArray[np.int16]] = []

    def _callback(
        indata: npt.NDArray[np.int16],
        _frame_count: int,
        _time_info: Any,
        _status: Any,
    ) -> None:
        # PortAudio reuses indata's buffer across callbacks. Copy before keeping.
        frames.append(indata.copy())

    try:
        stream = sd.InputStream(
            device=device,
            samplerate=samplerate,
            channels=channels,
            dtype=_DTYPE,
            callback=_callback,
        )
        stream.start()
    except sd.PortAudioError as exc:
        msg = f"no audio input device available: {exc}"
        raise RecorderError(msg) from exc

    return Recorder(wav_path, stream, frames, samplerate, channels)
