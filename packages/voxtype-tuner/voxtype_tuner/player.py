"""Stateful take playback through PortAudio, driven off the UI thread.

The old player was one-shot and blocking (``sd.play`` + ``sd.wait``): no handle,
no position, no pause. :class:`TakePlayer` replaces it with a small state machine
around an ``sd.OutputStream`` whose callback copies successive blocks out of the
loaded numpy buffer at an internal frame cursor. That cursor is the real playback
clock: :meth:`progress` reads it (frames written / total) so the waveform fill is
driven by where the audio actually is, not a free-running animation.

Two threads meet here, so the discipline mirrors :mod:`meter`:

- the PortAudio callback thread advances the cursor and, at the end, raises
  ``sd.CallbackStop`` and signals ``on_finished``. It touches ONLY the
  lock-guarded plain-int cursor/state, never any UI object.
- the UI/event-loop thread calls :meth:`toggle` / :meth:`stop` and reads
  :meth:`progress` from a repeating timer. The lock guards the cursor the
  callback writes against those reads.

``on_finished`` is invoked on the callback thread, so the caller (app.py) must
marshal it onto the event loop before touching any Slint instance.

The stream factory is injected (``open_fn``) exactly like ``wiring.InputMeter``
takes ``open_meter_stream``, so the cursor math unit-tests against a fake stream
with no audio device. A missing or corrupt WAV degrades to :class:`PlayerError`
(mirroring the old ``play`` and :func:`waveform.analyze_take`) rather than
letting a bare libsndfile error escape a worker thread.
"""

from __future__ import annotations

import threading
from typing import TYPE_CHECKING, Any

import sounddevice as sd
import soundfile as sf

if TYPE_CHECKING:
    from collections.abc import Callable

    import numpy as np
    import numpy.typing as npt

    # (outdata, frames, time_info, status) -> None, PortAudio's output callback.
    StreamCallback = Callable[[npt.NDArray[np.float32], int, Any, Any], None]
    # (samplerate, channels, callback, finished_callback) -> stream handle. The
    # handle only needs start()/stop()/close(), so it stays Any (as MeterStream
    # wraps its own opaque sd stream).
    OpenFn = Callable[[int, int, StreamCallback, Callable[[], None]], Any]

# Playback float PCM: the take WAV is read as float32 and fed straight through.
_DTYPE = "float32"

_IDLE = "idle"
_PLAYING = "playing"
_PAUSED = "paused"


class PlayerError(Exception):
    """Raised when playback cannot start (no output device, unreadable take)."""


def _open_output_stream(
    samplerate: int,
    channels: int,
    callback: StreamCallback,
    finished_callback: Callable[[], None],
) -> Any:
    """Default ``open_fn``: a real ``sd.OutputStream`` on the default device."""
    return sd.OutputStream(
        samplerate=samplerate,
        channels=channels,
        dtype=_DTYPE,
        callback=callback,
        finished_callback=finished_callback,
    )


class TakePlayer:
    """Play/pause/resume a single take, exposing a real playback position.

    :meth:`toggle` is the one entry the Play button drives: idle starts playback
    from the top, playing pauses at the current frame (``stream.stop`` halts
    PortAudio without discarding the cursor), paused resumes from it
    (``stream.start``). Natural end raises ``sd.CallbackStop`` in the callback,
    which fires ``on_finished`` and returns the player to idle.

    ``open_fn`` builds the output stream and is injected so tests drive the
    cursor math against a fake stream with no device. ``on_finished`` is called
    on the PortAudio callback thread on natural completion, so the caller must
    marshal it onto the event loop.
    """

    def __init__(
        self,
        *,
        open_fn: OpenFn = _open_output_stream,
        on_finished: Callable[[], None] | None = None,
    ) -> None:
        self._open_fn = open_fn
        self._on_finished = on_finished
        self._lock = threading.Lock()
        self._stream: Any = None
        self._data: npt.NDArray[np.float32] | None = None
        self._samplerate = 0
        self._channels = 0
        self._cursor = 0  # frames written so far (the playback clock)
        self._total = 0  # total frames in the loaded take
        self._state = _IDLE
        # A seek performed while idle, deferred to the next start(): idle Play
        # routes through start(), which reloads and would otherwise rewind to 0,
        # discarding the scrub. None means "start from the top". Cleared by
        # stop() so re-recording a take drops a scrub armed on the old one.
        self._pending_seek: float | None = None
        # Set by the callback under the lock at the moment it raises CallbackStop
        # for a natural end, so _finished can tell a real end-of-take from our
        # own pause/stop WITHOUT re-reading the cursor (which a racing seek may
        # have moved back below _total). See _finished.
        self._ended = False

    def toggle(self, path: str) -> None:
        """Start from idle, pause when playing, resume when paused.

        ``path`` is only consulted on a fresh start; a resume ignores it and
        continues the already-loaded take. Raises :class:`PlayerError` if the
        take at ``path`` cannot be read.
        """
        with self._lock:
            state = self._state
        if state == _PLAYING:
            self.pause()
        elif state == _PAUSED:
            self.resume()
        else:
            self.start(path)

    def start(self, path: str) -> None:
        """Load ``path`` and begin playback.

        Begins from a seek armed while idle (a scrub before Play), else from the
        top. stop() below clears that armed fraction, so it is snapshotted first
        and re-applied to the cursor after the load. Because stop() runs on every
        take-invalidating event (re-record, a stream session), a snapshot that
        survives to here can only belong to the take being loaded, so an old
        scrub can never leak onto a freshly recorded one.
        """
        with self._lock:
            pending = self._pending_seek
        self.stop()
        self._load(path)
        with self._lock:
            if pending is not None and self._total > 0:
                self._cursor = round(pending * self._total)
            samplerate = self._samplerate
            channels = self._channels
        try:
            stream = self._open_fn(samplerate, channels, self._callback, self._finished)
        except sd.PortAudioError as exc:
            msg = f"no audio output device available: {exc}"
            raise PlayerError(msg) from exc
        self._stream = stream
        with self._lock:
            self._state = _PLAYING
        try:
            stream.start()
        except sd.PortAudioError as exc:
            self.stop()
            msg = f"no audio output device available: {exc}"
            raise PlayerError(msg) from exc

    def pause(self) -> None:
        """Halt at the current frame, keeping the cursor for a later resume."""
        with self._lock:
            if self._state != _PLAYING:
                return
            self._state = _PAUSED
        stream = self._stream
        if stream is None:
            return
        try:
            # PortAudio stops feeding the callback but discards nothing, so the
            # cursor persists. finished_callback fires here too, but _finished
            # only signals completion (cursor < total), so a pause is silent.
            stream.stop()
        except sd.PortAudioError as exc:
            # The output device vanished under the paused stream. Reset to idle
            # so the controller and the UI cannot desync, and surface it (the
            # caller catches PlayerError, a raw PortAudioError would escape).
            self.stop()
            msg = f"no audio output device available: {exc}"
            raise PlayerError(msg) from exc

    def resume(self) -> None:
        """Continue playback from the paused frame."""
        with self._lock:
            if self._state != _PAUSED:
                return
            self._state = _PLAYING
        stream = self._stream
        if stream is None:
            return
        try:
            stream.start()
        except sd.PortAudioError as exc:
            # The output device vanished while paused. Reset to idle so the
            # controller and the UI cannot desync, and surface the failure as a
            # PlayerError rather than letting a raw PortAudioError escape.
            self.stop()
            msg = f"no audio output device available: {exc}"
            raise PlayerError(msg) from exc

    def stop(self) -> None:
        """Halt playback, discard the stream, rewind the cursor, drop the arm."""
        stream, self._stream = self._stream, None
        with self._lock:
            self._state = _IDLE
            self._cursor = 0
            # A fresh stop cancels any armed idle-scrub and clears the natural-end
            # flag, so a following stream.stop() below cannot read as completion.
            self._pending_seek = None
            self._ended = False
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except sd.PortAudioError:
                # Nothing to finalize on an output tear-down: the stream is being
                # dropped either way, so a PortAudio hiccup must not surface.
                pass

    def is_playing(self) -> bool:
        with self._lock:
            return self._state == _PLAYING

    def progress(self) -> float:
        """Playback position as a fraction in ``[0, 1]`` (0 when idle/finished)."""
        with self._lock:
            if self._total <= 0:
                return 0.0
            return min(1.0, self._cursor / self._total)

    def seek(self, fraction: float) -> bool:
        """Move the playback clock to ``fraction`` of the take (clamped [0, 1]).

        A pure cursor move under the same lock the callback advances, so it is
        correct in every state and never tears down the stream. Returns whether a
        real position was established, so the caller only paints a fill it can
        back up (never a phantom fill over a seek that went nowhere):

        - playing: the callback thread simply keeps writing from the new cursor,
          so audio continues from here (a resume/restart is not needed).
        - paused: the frozen cursor moves, so the later resume continues here.
        - idle: the fraction is armed as a pending seek so the next start()
          begins there instead of rewinding to 0, and the cursor also moves live
          when a take is already loaded so :meth:`progress` reflects it at once.
          Armed even before the first load (``_total`` is 0), so a freshly
          recorded, never-played take still plays back from the sought point.
        """
        clamped = min(1.0, max(0.0, fraction))
        with self._lock:
            loaded = self._data is not None and self._total > 0
            if loaded:
                self._cursor = round(clamped * self._total)
            if self._state == _IDLE:
                self._pending_seek = clamped
                return True
            return loaded

    def _load(self, path: str) -> None:
        try:
            data, samplerate = sf.read(path, dtype=_DTYPE, always_2d=True)
        except (sf.LibsndfileError, OSError, RuntimeError) as exc:
            # Missing take (nothing recorded, no seeded sample) or corrupt data:
            # reach the UI as a PlayerError, never escape a worker thread.
            msg = f"cannot read recording: {exc}"
            raise PlayerError(msg) from exc
        frames, channels = data.shape
        with self._lock:
            self._data = data
            self._samplerate = int(samplerate)
            self._channels = int(channels)
            self._total = int(frames)
            self._cursor = 0
            # A fresh take has not ended yet: clear any completion flag left from
            # the previous take so its first block cannot read as already done.
            self._ended = False

    def _callback(
        self,
        outdata: npt.NDArray[np.float32],
        frames: int,
        _time_info: Any,
        _status: Any,
    ) -> None:
        # PortAudio callback thread: touch ONLY the lock-guarded cursor/data,
        # never a Slint instance. Raise CallbackStop (which sounddevice expects)
        # once the take is exhausted so finished_callback fires.
        with self._lock:
            data = self._data
            cursor = self._cursor
            total = self._total
        if data is None or cursor >= total:
            outdata.fill(0.0)
            if data is not None:
                # Already exhausted (a stray block past the end): flag the natural
                # end so _finished treats it as completion, not a pause/stop.
                with self._lock:
                    self._ended = True
            raise sd.CallbackStop
        n = min(frames, total - cursor)
        outdata[:n] = data[cursor : cursor + n]
        if n < frames:
            outdata[n:].fill(0.0)
        new_cursor = cursor + n
        ended = new_cursor >= total
        with self._lock:
            self._cursor = new_cursor
            # Latch the natural end together with the final cursor write, so a
            # seek landing after this (moving the cursor back) cannot erase the
            # fact that the take reached its end. _finished reads this flag.
            if ended:
                self._ended = True
        if ended:
            raise sd.CallbackStop

    def _finished(self) -> None:
        # Called on the callback thread whenever the stream goes inactive: a
        # natural end OR our own pause/stop. Branch on the flag the callback
        # latched at CallbackStop, NOT on a re-read of cursor >= total: a seek
        # that moved the cursor back in the race window between the final block
        # and this callback would otherwise mask the completion, leaving the
        # player stuck reporting "playing" over a dead stream. A pause/stop never
        # set the flag, so it stays silent and keeps the cursor frozen.
        with self._lock:
            completed = self._ended
        if not completed:
            return
        with self._lock:
            self._ended = False
            self._state = _IDLE
            self._cursor = 0
        if self._on_finished is not None:
            self._on_finished()
