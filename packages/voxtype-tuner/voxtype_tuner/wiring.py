"""UI-independent glue: build TranscribeParams from control values, serialize
the language checklist, and own the single-take recording state machine.

Deliberately free of any ``slint`` import so these helpers unit-test without the
native UI lib, and app.py layers the Slint event-loop marshalling on top.
"""

from __future__ import annotations

import threading
from typing import TYPE_CHECKING

from voxtype_tuner.meter import MeterStream, open_meter_stream
from voxtype_tuner.params import AUTO_LANGUAGE, TranscribeParams
from voxtype_tuner.recorder import Recorder, RecorderError, start_recording

if TYPE_CHECKING:
    from collections.abc import Callable

    from voxtype_tuner.models import DownloadProgress
    from voxtype_tuner.transcribe import TranscribeResult


# Fallbacks for the two numeric combos when the read yields no usable number.
# Same values defaults.py seeds when a config omits the field, so a fallback at
# startup lands on the built-in baseline rather than an arbitrary constant.
_DEFAULT_VAD_THRESHOLD = 0.4
_DEFAULT_MAX_DURATION = 60


def _combo_float(value: str, fallback: float) -> float:
    """Parse a combo's string value as a float, or fall back on a bad read.

    Mirrors ``defaults._float``: a value that will not parse yields the default
    instead of raising. See :func:`build_params` for why the read can be blank.
    """
    try:
        return float(value)
    except ValueError:
        return fallback


def _combo_int(value: str, fallback: int) -> int:
    """Parse a combo's string value as an int, or fall back on a bad read.

    Mirrors ``defaults._int``: a value that will not parse yields the default
    instead of raising. See :func:`build_params` for why the read can be blank.
    """
    try:
        return int(value)
    except ValueError:
        return fallback


def build_params(
    engine: str,
    model: str,
    language: str,
    prompt: str,
    vad: bool,
    vad_threshold: str,
    max_duration: str,
    streaming: bool = False,
    device: str = "default",
) -> TranscribeParams:
    """Assemble TranscribeParams from the live control values.

    The threshold and max-duration combos surface their values as strings
    ("0.40", "60"). Coerce those two numeric fields here so the rest of the
    pipeline sees the typed dataclass Track B's argv builder expects.

    Both combos are backed by a reactive ``list[index]`` Slint binding
    (``sel-vad-threshold``, ``sel-max-duration``). Read synchronously from
    Python at configure time, before the model settles, that binding reads back
    as ``""`` rather than the selected row, so a bare ``float("")`` / ``int("")``
    would raise and crash startup. Route the two coercions through
    :func:`_combo_float` / :func:`_combo_int` so a blank or otherwise
    non-numeric read falls back to the built-in default while every real value
    still coerces exactly.

    ``streaming`` is the parakeet config toggle, defaulted off so callers that
    predate it (and the non-parakeet paths) stay valid. ``device`` is the
    selected recording input's voxtype ``[audio] device`` string, defaulted to
    the system default for the same reason.
    """
    return TranscribeParams(
        engine=engine,
        model=model,
        language=language,
        initial_prompt=prompt,
        vad=vad,
        vad_threshold=_combo_float(vad_threshold, _DEFAULT_VAD_THRESHOLD),
        max_duration=_combo_int(max_duration, _DEFAULT_MAX_DURATION),
        streaming=streaming,
        device=device,
    )


def serialize_language(auto: bool, codes: list[str], checked: list[bool]) -> str:
    """The ``--language`` value for the popup checklist state.

    Auto is exclusive, and "nothing checked" has no valid CLI form of its own,
    so both read as voxtype's unconstrained ``auto``. Otherwise the checked
    codes join comma-separated in row order (the catalog-then-extras order
    defaults.py seeds in), so an untouched selection round-trips verbatim.
    """
    selected = [code for code, on in zip(codes, checked, strict=False) if on]
    if auto or not selected:
        return AUTO_LANGUAGE
    return ",".join(selected)


# At most this many selected codes are spelled out in the pill label.
_PILL_MAX_CODES = 2


def summarize_language(auto: bool, codes: list[str], checked: list[bool]) -> str:
    """The language pill's label: compact but state-revealing.

    One or two selections show their codes ("EN", "EN + DE"). Three or more
    collapse to a count, since the pill must not stretch the params row.
    """
    selected = [code for code, on in zip(codes, checked, strict=False) if on]
    if auto or not selected:
        return "Auto"
    if len(selected) == 1:
        return selected[0].upper()
    if len(selected) == _PILL_MAX_CODES:
        return f"{selected[0].upper()} + {selected[1].upper()}"
    return f"{len(selected)} languages"


def transcription_output(result: TranscribeResult) -> str:
    """Clean, human-readable text for the transcription field.

    On success this is the recovered transcript (transcribe.py has already
    stripped voxtype's preamble/tracing). On failure it collapses to a single
    ``transcription failed: <reason>`` line rather than the raw multi-line
    stderr, so the field never fills with a wall of tracing.
    """
    if result.error is None:
        return result.text
    lines = [ln.strip() for ln in result.error.splitlines() if ln.strip()]
    reason = lines[-1] if lines else "unknown error"
    return f"transcription failed: {reason}"


def format_download_progress(progress: DownloadProgress) -> str:
    """The status caption for an in-flight model download.

    The caption carries the numbers. The busy spinner beside it carries the
    motion. Percent when the catalog knows the artifact's expected size, raw
    MB otherwise (an off-catalog model still visibly moves), bare before the
    first byte lands.
    """
    percent = progress.percent
    if percent is not None:
        return f"downloading… {percent}%"
    if progress.done_bytes > 0:
        return f"downloading… {progress.done_bytes // (1024 * 1024)} MB"
    return "downloading…"


class TakeRecorder:
    """Capture state machine that toggles the take's recording off the UI thread.

    A press either starts capture (storing the live handle) or stops the running
    one. Every start/stop is dispatched through ``run_bg`` so the caller's UI
    thread never blocks on device I/O. The lock guards the handle against the
    worker threads that populate it. ``on_state`` reports the actual capture
    state (True once the device is really open, False once it stopped) so the
    UI's Record/Stop label follows the hardware, not the click. ``device_for``
    is read on the caller's (UI / event-loop) thread at each toggle so capture
    opens the picker's currently-selected PortAudio device index (``None`` = the
    system default). It reads a Slint instance property, which the unsendable
    ``ComponentInstance`` forbids touching from a ``run_bg`` worker.
    """

    def __init__(
        self,
        path_for: Callable[[], str],
        run_bg: Callable[[Callable[[], None]], None],
        on_error: Callable[[str], None],
        on_state: Callable[[bool], None] = lambda _active: None,
        device_for: Callable[[], int | None] = lambda: None,
        start_fn: Callable[[str, int | None], Recorder] = start_recording,
    ) -> None:
        self._path_for = path_for
        self._run_bg = run_bg
        self._on_error = on_error
        self._on_state = on_state
        self._device_for = device_for
        self._start_fn = start_fn
        self._lock = threading.Lock()
        self._handle: Recorder | None = None
        self._starting = False

    def toggle(self) -> None:
        """Start capturing if idle, else stop the running capture."""
        with self._lock:
            if self._handle is not None:
                handle: Recorder | None = self._handle
                self._handle = None
            elif self._starting:
                # A prior press is still opening the device. Ignore this one so a
                # double-tap can't spawn a second capture we'd never stop.
                return
            else:
                handle = None
                self._starting = True
        if handle is None:
            # device_for reads a Slint instance property, so snapshot it here on
            # the caller's (UI) thread. The run_bg worker must never touch it.
            device = self._device_for()
            self._run_bg(lambda: self._start(device))
        else:
            self._run_bg(lambda: self._stop(handle))

    def is_recording(self) -> bool:
        with self._lock:
            return self._handle is not None

    def _start(self, device: int | None) -> None:
        try:
            handle = self._start_fn(self._path_for(), device)
        except RecorderError as exc:
            with self._lock:
                self._starting = False
            self._on_error(str(exc))
            return
        with self._lock:
            self._starting = False
            self._handle = handle
        self._on_state(True)

    def _stop(self, handle: Recorder) -> None:
        try:
            handle.stop()
        except RecorderError as exc:
            self._on_error(str(exc))
        finally:
            # The handle is already dropped: whatever the teardown said, no
            # capture is running anymore, so the UI returns to Record.
            self._on_state(False)


class InputMeter:
    """Idle-only input-level meter obeying the single-owner device policy.

    A meter and a Record/Stream capture cannot both hold the same input device:
    an ALSA ``hw:`` PCM is typically exclusive and PortAudio does not multiplex,
    so a second open on the device Record just picked would fail. So this holds
    ONE cheap :class:`~voxtype_tuner.meter.MeterStream` on the selected device
    ONLY while the app is idle, and yields it the instant Record or a Stream
    session needs the mic.

    All transitions run on the UI thread, so open and close are serialized and
    there is never more than one stream on a device:

    - :meth:`start` / :meth:`stop`: the app-lifetime on/off, called around the
      event loop. Nothing opens until :meth:`start`, so a test that never starts
      the meter touches no audio, exactly like :class:`TakeRecorder`.
    - :meth:`pause` / :meth:`resume`: Record or a Stream session takes the mic,
      then gives it back. :meth:`pause` closes SYNCHRONOUSLY, so the device is
      free before capture opens it. The bar itself reads flat during capture
      because the UI zeroes it while recording or streaming, so no cross-thread
      level write is needed on this UI-thread path.
    - :meth:`retap`: the selected device changed while idle, so reopen on the
      new one. ``device_for`` is read afresh at each open (the ``TakeRecorder``
      read-at-start idiom), so the meter always taps the device the picker
      shows.

    ``on_level`` is handed the smoothed level from PortAudio's callback thread
    (the only place it is called), so the caller must marshal it onto the event
    loop. Opening never raises: a device that will not open leaves the meter
    flat. ``available_fn`` gates opening on whether the host has any input at
    all, so a no-microphone host is never even asked to open a stream.
    """

    def __init__(
        self,
        on_level: Callable[[float], None],
        device_for: Callable[[], int | None] = lambda: None,
        open_fn: Callable[
            [int | None, Callable[[float], None], Callable[[], None]],
            MeterStream | None,
        ] = open_meter_stream,
        available_fn: Callable[[], bool] = lambda: True,
        on_lost: Callable[[], None] = lambda: None,
    ) -> None:
        self._on_level = on_level
        self._device_for = device_for
        self._open_fn = open_fn
        self._available_fn = available_fn
        self._on_lost = on_lost
        self._stream: MeterStream | None = None
        self._active = False
        self._paused = False

    def start(self) -> None:
        """Begin metering while idle (the app entered its event loop)."""
        self._active = True
        self._open_if_idle()

    def stop(self) -> None:
        """Stop metering for good (the app is exiting). Yields the device."""
        self._active = False
        self._close_stream()

    def pause(self) -> None:
        """Yield the device to Record or a Stream session.

        Synchronous, so the stream is closed before the caller opens capture on
        the same device.
        """
        self._paused = True
        self._close_stream()

    def resume(self) -> None:
        """Reclaim the device once Record or a Stream session released it."""
        self._paused = False
        self._open_if_idle()

    def retap(self) -> None:
        """Reopen on the currently selected device (a device change while idle)."""
        self._close_stream()
        self._open_if_idle()

    def handle_device_lost(self) -> None:
        """Drop a stream whose device vanished mid-capture (UI thread).

        Called after the callback thread's loss signal has been marshalled onto
        the event loop. The PortAudio stream already errored itself, so just
        stop and release the dead handle. The caller flips the availability gate
        to False, so :meth:`_open_if_idle` will not reopen until an explicit
        rescan re-arms it.
        """
        self._close_stream()

    def _open_if_idle(self) -> None:
        # Open only when the app wants metering, nothing else owns the mic, no
        # stream is already live, AND the host actually has an input to tap.
        # ``available_fn`` gates the whole open so a no-microphone host never
        # reaches ``open_fn`` (whose PortAudio open would spew ALSA warnings to
        # fd 2 before failing). It is re-checked on every open, so a device that
        # appears while idle is picked up on the next retap/resume. ``open_fn``
        # itself still returns None when a present device cannot be opened, so
        # the meter stays flat with no error to the UI.
        if (
            self._active
            and not self._paused
            and self._stream is None
            and self._available_fn()
        ):
            self._stream = self._open_fn(
                self._device_for(), self._on_level, self._on_lost
            )

    def _close_stream(self) -> None:
        stream, self._stream = self._stream, None
        if stream is not None:
            stream.stop()
