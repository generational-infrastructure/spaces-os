"""Tests for the UI-independent wiring: value→params coercion, the transcript
selection rule, the language selection serializer/summary, and the single-take
recorder state machine.

These import ``voxtype_tuner.wiring`` but never ``slint``, so they exercise the
orchestration logic without the native UI lib. The recorder is driven with a
fake capture handle and a controllable ``run_bg`` so start/stop and the
double-press guard are tested deterministically, no audio device involved.
"""

import threading
from collections.abc import Callable

from voxtype_tuner.models import DownloadProgress
from voxtype_tuner.params import TranscribeParams
from voxtype_tuner.recorder import Recorder, RecorderError
from voxtype_tuner.transcribe import TranscribeResult
from voxtype_tuner.wiring import (
    TakeRecorder,
    build_params,
    format_download_progress,
    serialize_language,
    summarize_language,
    transcription_output,
)


def test_build_params_coerces_numeric_combo_strings() -> None:
    p = build_params(
        engine="whisper",
        model="base.en",
        language="en",
        prompt="hi",
        vad=True,
        vad_threshold="0.40",
        max_duration="60",
    )
    assert p == TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="hi",
        vad=True,
        vad_threshold=0.4,
        max_duration=60,
    )
    # The two numeric fields must be real float/int, not the combo's strings.
    assert isinstance(p.vad_threshold, float)
    assert isinstance(p.max_duration, int)


def test_build_params_blank_numeric_reads_fall_back_to_defaults() -> None:
    # The reactive sel-vad-threshold / sel-max-duration bindings read back as
    # "" when Python reads them synchronously at configure time (before the
    # combo model settles). A bare float("")/int("") would crash startup, so
    # build_params must fall back to the built-in defaults instead.
    p = build_params(
        engine="whisper",
        model="base.en",
        language="en",
        prompt="",
        vad=True,
        vad_threshold="",
        max_duration="",
    )
    assert p.vad_threshold == 0.4
    assert p.max_duration == 60
    assert isinstance(p.vad_threshold, float)
    assert isinstance(p.max_duration, int)


def test_build_params_non_numeric_reads_fall_back_to_defaults() -> None:
    # Any non-numeric read (a placeholder row, a stray label) must fall back the
    # same way rather than raise, catching ValueError only.
    p = build_params(
        engine="whisper",
        model="base.en",
        language="en",
        prompt="",
        vad=True,
        vad_threshold="n/a",
        max_duration="auto",
    )
    assert p.vad_threshold == 0.4
    assert p.max_duration == 60


def test_build_params_carries_vad_off_and_extremes() -> None:
    p = build_params(
        engine="parakeet",
        model="parakeet-tdt-0.6b-v3",
        language="auto",
        prompt="",
        vad=False,
        vad_threshold="0.70",
        max_duration="120",
    )
    assert p.vad is False
    assert p.vad_threshold == 0.7
    assert p.max_duration == 120


def _result(text: str = "", error: str | None = None) -> TranscribeResult:
    return TranscribeResult(
        text=text,
        raw_stdout="",
        argv=[],
        returncode=0,
        duration_s=0.0,
        error=error,
    )


def test_transcription_output_prefers_clean_text_when_no_error() -> None:
    assert transcription_output(_result(text="hello world")) == "hello world"


def test_transcription_output_shows_short_reason_on_error() -> None:
    got = transcription_output(_result(text="", error="voxtype exited with code 1"))
    assert got == "transcription failed: voxtype exited with code 1"


def test_transcription_output_collapses_multiline_error_to_last_line() -> None:
    # A real stderr wall must not fill the field: only a single cause line shows.
    err = "whisper_init: loading model\nfailed to load model\nerror: model not found"
    got = transcription_output(_result(text="", error=err))
    assert got == "transcription failed: error: model not found"
    assert "\n" not in got
    assert "whisper_init" not in got


CODES = ["en", "de", "fr", "es"]


def test_serialize_language_auto_wins() -> None:
    # Auto is exclusive: whatever the checkboxes held before switching to auto
    # must not leak into the CLI value.
    assert serialize_language(True, CODES, [True, True, False, False]) == "auto"


def test_serialize_language_single_and_multi_join_in_row_order() -> None:
    assert serialize_language(False, CODES, [True, False, False, False]) == "en"
    assert serialize_language(False, CODES, [True, True, False, False]) == "en,de"
    assert serialize_language(False, CODES, [False, True, False, True]) == "de,es"


def test_serialize_language_nothing_checked_snaps_to_auto() -> None:
    # The invalid "no language at all" state serializes as auto rather than an
    # empty --language voxtype would reject.
    assert serialize_language(False, CODES, [False, False, False, False]) == "auto"


def test_summarize_language_states() -> None:
    assert summarize_language(True, CODES, [False, False, False, False]) == "Auto"
    assert summarize_language(False, CODES, [True, False, False, False]) == "EN"
    assert summarize_language(False, CODES, [True, True, False, False]) == "EN + DE"
    assert summarize_language(False, CODES, [True, True, True, False]) == "3 languages"
    assert summarize_language(False, CODES, [True, True, True, True]) == "4 languages"


def test_summarize_language_nothing_checked_reads_auto() -> None:
    assert summarize_language(False, CODES, [False, False, False, False]) == "Auto"


class FakeRecorder(Recorder):
    """A capture handle that records that it was stopped, bypassing PortAudio."""

    def __init__(self) -> None:
        self.stopped = False

    def stop(self) -> None:
        self.stopped = True


def _immediate(work: Callable[[], None]) -> None:
    work()


def test_toggle_starts_then_stops_and_notifies_state() -> None:
    made: list[tuple[str, int | None, FakeRecorder]] = []
    states: list[bool] = []

    def start_fn(path: str, device: int | None) -> Recorder:
        rec = FakeRecorder()
        made.append((path, device, rec))
        return rec

    rec = TakeRecorder(
        path_for=lambda: "/data/take.wav",
        run_bg=_immediate,
        on_error=lambda _m: None,
        on_state=states.append,
        device_for=lambda: 3,
        start_fn=start_fn,
    )

    rec.toggle()
    assert rec.is_recording() is True
    assert made[0][0] == "/data/take.wav"
    # The picker's selected PortAudio index reaches the capture call.
    assert made[0][1] == 3
    assert states == [True]

    rec.toggle()
    assert rec.is_recording() is False
    assert made[0][2].stopped is True
    assert states == [True, False]


def test_start_failure_surfaces_error_and_stays_idle() -> None:
    errors: list[str] = []
    states: list[bool] = []

    def boom(_path: str, _device: int | None) -> Recorder:
        msg = "no audio input device available"
        raise RecorderError(msg)

    rec = TakeRecorder(
        path_for=lambda: "/data/take.wav",
        run_bg=_immediate,
        on_error=errors.append,
        on_state=states.append,
        start_fn=boom,
    )

    rec.toggle()
    assert errors == ["no audio input device available"]
    assert rec.is_recording() is False
    # The state callback never claimed "recording", so the UI never shows Stop.
    assert states == []


def test_stop_failure_still_reports_idle_state() -> None:
    # The handle is dropped on stop even when the device teardown errors: the
    # capture is over either way, so the UI must return to the Record label.
    errors: list[str] = []
    states: list[bool] = []

    class ExplodingRecorder(Recorder):
        def __init__(self) -> None:
            pass  # bypass the real device-handle constructor

        def stop(self) -> None:
            msg = "device wedged"
            raise RecorderError(msg)

    rec = TakeRecorder(
        path_for=lambda: "/data/take.wav",
        run_bg=_immediate,
        on_error=errors.append,
        on_state=states.append,
        start_fn=lambda _path, _device: ExplodingRecorder(),
    )

    rec.toggle()
    rec.toggle()

    assert errors == ["device wedged"]
    assert rec.is_recording() is False
    assert states == [True, False]


def test_double_press_while_starting_spawns_one_capture() -> None:
    pending: list[Callable[[], None]] = []
    made: list[FakeRecorder] = []

    def start_fn(_path: str, _device: int | None) -> Recorder:
        rec = FakeRecorder()
        made.append(rec)
        return rec

    rec = TakeRecorder(
        path_for=lambda: "/data/take.wav",
        run_bg=pending.append,  # defer: nothing runs until we drain it
        on_error=lambda _m: None,
        start_fn=start_fn,
    )

    rec.toggle()  # reserves the take, enqueues the start
    rec.toggle()  # still opening the device: ignored, no second start enqueued
    assert len(pending) == 1

    pending[0]()  # complete the deferred start
    assert rec.is_recording() is True
    assert len(made) == 1


def test_device_index_is_read_on_the_toggle_thread_not_the_worker() -> None:
    # Regression for the P0 unsendable-ComponentInstance panic. device_for reads a
    # Slint instance property (instance.device_index), which pyo3 forbids off the
    # event-loop thread. Before the fix, TakeRecorder._start evaluated device_for on
    # the run_bg worker thread, so with a real ComponentInstance the process aborted
    # ("unsendable ... sent to another thread"). Drive a real background run_bg and
    # assert device_for ran on the thread that called toggle().
    toggle_thread = threading.get_ident()
    device_threads: list[int] = []
    started = threading.Event()

    def real_run_bg(work: Callable[[], None]) -> None:
        threading.Thread(target=work, daemon=True).start()

    def device_for() -> int | None:
        device_threads.append(threading.get_ident())
        return 0

    def start_fn(_path: str, _device: int | None) -> Recorder:
        started.set()
        return FakeRecorder()

    rec = TakeRecorder(
        path_for=lambda: "/data/take.wav",
        run_bg=real_run_bg,
        on_error=lambda _m: None,
        device_for=device_for,
        start_fn=start_fn,
    )

    rec.toggle()
    assert started.wait(5.0), "capture never started"
    assert device_threads == [toggle_thread]


def test_format_download_progress_percent_when_total_known() -> None:
    # The caption carries the numbers (the busy spinner carries the motion):
    # percent when the catalog knows the artifact size, else raw MB so a
    # multi-GB fetch of an off-catalog model still visibly moves.
    half = DownloadProgress(done_bytes=500, total_bytes=1000)
    assert format_download_progress(half) == "downloading… 50%"


def test_format_download_progress_megabytes_when_total_unknown() -> None:
    some = DownloadProgress(done_bytes=213 * 1024 * 1024, total_bytes=None)
    assert format_download_progress(some) == "downloading… 213 MB"


def test_format_download_progress_bare_before_first_byte() -> None:
    nothing = DownloadProgress(done_bytes=0, total_bytes=None)
    assert format_download_progress(nothing) == "downloading…"
