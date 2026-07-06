"""Live input-level metering off a cheap idle-only capture stream.

The meter taps the SELECTED recording device the moment the app is idle, reads
one level per audio block on PortAudio's own callback thread, and hands a
decay-smoothed level back through a caller-supplied sink. It never writes any
WAV: it is a cosmetic affordance, so a missing input device (common on headless
or CI hosts) degrades to a flat/zero meter (:func:`open_meter_stream` returns
``None``) rather than a raised error.

Two layers, both slint-free so they unit-test without the native UI lib:

- the level math (:func:`peak_level`, :func:`rms_level`, :class:`LevelMeter`),
  pure functions over an int16 block plus a fast-attack/slow-release smoother.
- the stream lifecycle (:class:`MeterStream`, :func:`open_meter_stream`), the
  ``sd.InputStream`` open/start/stop+close mirror of :mod:`recorder`.

The single-owner device policy (one stream per device, never two) lives one
level up in ``wiring.InputMeter``, which starts and yields this stream around
Record and a Stream session.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

import numpy as np
import sounddevice as sd

from voxtype_tuner.stderr_guard import suppress_c_stderr

if TYPE_CHECKING:
    from collections.abc import Callable

    import numpy.typing as npt

# Same engine-ready capture target as the recorder: 16-bit mono at 16 kHz.
_DTYPE = "int16"
_SAMPLERATE = 16000
_CHANNELS = 1
# ~32 ms per block at 16 kHz: responsive enough to feel live, cheap enough to
# ignore. "low" latency keeps the callback prompt.
_BLOCKSIZE = 512

# int16 full scale. A sample divided by this lands the level in [0, 1].
_FULL_SCALE = 32768.0

# Fast attack, slow release: a louder block jumps the level instantly, a quieter
# one decays by this factor per block (~0.5 s to fall to a tenth), so the bar
# reads as a calm envelope rather than a jittery instantaneous reading.
_RELEASE_DECAY = 0.86

# Push only every Nth block so the UI update rate stays ~15 Hz (calm) even
# though the callback fires ~31 times a second.
_PUSH_EVERY = 2


def peak_level(block: npt.NDArray[np.int16]) -> float:
    """Peak absolute sample of an int16 block, normalized to ``[0, 1]``.

    Widened to int32 before ``abs`` so the int16 minimum (-32768, whose
    negation overflows int16) reads as full scale rather than wrapping.
    """
    if block.size == 0:
        return 0.0
    peak = float(np.max(np.abs(block.astype(np.int32))))
    return min(1.0, peak / _FULL_SCALE)


def rms_level(block: npt.NDArray[np.int16]) -> float:
    """Root-mean-square of an int16 block, normalized to ``[0, 1]``.

    The perceptual-loudness companion to :func:`peak_level`. Computed in float
    so the square never overflows the integer type.
    """
    if block.size == 0:
        return 0.0
    samples = block.astype(np.float64)
    rms = float(np.sqrt(np.mean(np.square(samples))))
    return min(1.0, rms / _FULL_SCALE)


class LevelMeter:
    """Per-block level with a fast-attack, slow-release smoother.

    :meth:`push` folds one block into the running level: it snaps up to a louder
    block immediately (attack) and decays toward silence by ``decay`` per block
    otherwise (release). ``level_fn`` selects the per-block measure (peak by
    default, or :func:`rms_level`).
    """

    def __init__(
        self,
        *,
        decay: float = _RELEASE_DECAY,
        level_fn: Callable[[npt.NDArray[np.int16]], float] = peak_level,
    ) -> None:
        self._decay = decay
        self._level_fn = level_fn
        self.value = 0.0

    def push(self, block: npt.NDArray[np.int16]) -> float:
        level = self._level_fn(block)
        self.value = level if level >= self.value else self.value * self._decay
        return self.value


class MeterStream:
    """A live meter capture handle. :meth:`stop` halts and closes the stream."""

    def __init__(self, stream: Any) -> None:
        self._stream = stream

    def stop(self) -> None:
        """Stop and close the underlying stream, yielding the device.

        Swallows a PortAudio teardown hiccup: the meter is a cosmetic idle tap
        with nothing to finalize, so a stop error must never surface in the UI.
        The device is being released either way.
        """
        try:
            self._stream.stop()
            self._stream.close()
        except sd.PortAudioError:
            pass


def open_meter_stream(
    device: int | None,
    on_level: Callable[[float], None],
    on_lost: Callable[[], None] | None = None,
    *,
    samplerate: int = _SAMPLERATE,
    channels: int = _CHANNELS,
    blocksize: int = _BLOCKSIZE,
    decay: float = _RELEASE_DECAY,
    push_every: int = _PUSH_EVERY,
    level_fn: Callable[[npt.NDArray[np.int16]], float] = peak_level,
) -> MeterStream | None:
    """Open a cheap input stream on ``device`` and push smoothed levels.

    ``device`` is the PortAudio device INDEX to tap (``None`` = PortAudio's own
    default input), matching :func:`recorder.start_recording`. Each captured
    block is folded into a :class:`LevelMeter` on PortAudio's callback thread,
    and every ``push_every``-th block the smoothed level is handed to
    ``on_level``. That sink is called OFF the UI thread, so the caller must
    marshal it onto the event loop before touching any UI state.

    ``on_lost`` (also called on the callback thread, so it too must marshal) is
    invoked once if the tapped device vanishes mid-stream: the callback catches
    the error so no Python exception escapes into PortAudio's C stack, and the
    caller degrades to the no-microphone state rather than crashing or spewing.

    Returns a live :class:`MeterStream`, or ``None`` when the device cannot be
    opened. It never raises: a meter is a cosmetic affordance, so a host with no
    input device degrades to a flat/zero meter instead of an error.
    """
    meter = LevelMeter(decay=decay, level_fn=level_fn)
    count = 0
    lost = False

    def _callback(
        indata: npt.NDArray[np.int16],
        _frame_count: int,
        _time_info: Any,
        _status: Any,
    ) -> None:
        nonlocal count, lost
        if lost:
            # The device already vanished. Swallow the trailing callbacks
            # PortAudio may still fire before the caller closes the stream.
            return
        try:
            value = meter.push(indata)
            count += 1
            if count % push_every == 0:
                on_level(value)
        except Exception:  # noqa: BLE001
            # PortAudio's C callback thread: a Python exception must NEVER
            # escape back into C (that is undefined behaviour), and any failure
            # here means the tapped device is gone (unplugged mid-stream). Flag
            # it, signal the loss once so the caller can stop the stream and
            # degrade to the no-microphone state, and swallow the rest.
            lost = True
            if on_lost is not None:
                on_lost()

    try:
        # PortAudio probes ALSA in C as it opens the stream and can write
        # warnings straight to fd 2 on a finicky host, so silence JUST the open
        # (not the surrounding Python, where a real error still needs to
        # surface). The common no-input case never reaches here at all: the app
        # gates on devices.has_input_device and skips the open entirely, so this
        # guard only covers the residual chatter a present-but-fussy device can
        # still emit.
        with suppress_c_stderr():
            stream = sd.InputStream(
                device=device,
                samplerate=samplerate,
                channels=channels,
                dtype=_DTYPE,
                blocksize=blocksize,
                latency="low",
                callback=_callback,
            )
            stream.start()
    except sd.PortAudioError:
        return None

    return MeterStream(stream)
