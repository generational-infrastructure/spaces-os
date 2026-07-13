"""Tests for the Slint-instance wiring in ``voxtype_tuner.app``.

Unlike ``test_wiring`` (which never imports ``slint``), these drive the real
``configure`` against a duck-typed stand-in for the ``MainWindow`` instance.
``configure`` only sets catalog/model/callback attributes and reads the
``sel_*`` values back, and the UI-thread callbacks run synchronously, so no
window or event loop is needed to exercise it end to end.
"""

from __future__ import annotations

import datetime
import importlib.util
import pathlib
import threading
import time
import wave
from dataclasses import replace
from typing import TYPE_CHECKING, Any, ClassVar

import numpy as np
import pytest
import sounddevice as sd

# Unlike the pure helpers, this module drives the slint-integrated configure(),
# so it needs the native slint lib on the loader path (scripts/env.sh). Skip
# cleanly rather than fail collection when it is run without that setup. Bind
# the module from importorskip's return value (the optional real-window test
# needs slint.load_file) rather than a second `import slint`, which would sit in
# a mixed import group the formatter and the isort lint disagree on.
slint = pytest.importorskip("slint")

from voxtype_tuner import (
    app,
    apply,
    defaults,
    models,
    slots,
    streaming,
)
from voxtype_tuner.devices import SYSTEM_DEFAULT, InputDevice
from voxtype_tuner.meter import MeterStream
from voxtype_tuner.params import TranscribeParams
from voxtype_tuner.player import PlayerError
from voxtype_tuner.transcribe import TranscribeResult
from voxtype_tuner.wiring import InputMeter, build_params

if TYPE_CHECKING:
    from collections.abc import Callable


class FakeWindow:
    """Attribute bag standing in for the Slint ``MainWindow`` instance.

    ``configure`` writes every catalog/model/callback as a plain attribute and
    reads only the ``sel_*`` values back, so a bare object with those seeded is
    enough to bind and fire the callbacks.
    """

    def __init__(self) -> None:
        self.sel_engine = "whisper"
        self.sel_model = "tiny"
        self.sel_prompt = ""
        self.sel_vad = True
        self.sel_vad_threshold = "0.40"
        self.sel_max_duration = "60"
        self.transcription = ""
        self.transcription_source = ""
        self.transcription_timing = ""
        self.copy_feedback = ""
        self.model_status = ""
        self.model_state = "absent"
        self.model_status_error = False
        self.take_status = ""
        # Take playback state: whether the take is actively playing (drives the
        # Play/Pause swap) and the fill fraction the progress timer samples.
        self.playing = False
        self.playback_progress = 0.0
        # Live input-level meter reading, pushed by the meter wiring.
        self.input_level = 0.0
        # Whether the host has a usable recording input, set by configure() and
        # each rescan. Defaults True so mic-having tests are unaffected.
        self.input_available = True
        # Guards against concurrent downloads/transcribes, toggled by the wiring.
        self.downloading = False
        self.transcribing = False
        self.recording = False
        self.streaming = False
        self.stream_status = ""
        self.stream_visible = False
        self.streaming_available = False
        self.stream_startable = False
        self.param_streaming = False
        self.sel_streaming = False
        self.stream_note = ""
        self.apply_available = False
        self.apply_status = ""
        self.apply_status_error = False
        self.applying = False
        self.override_exists = False
        self.apply_preview_source = ""
        self.focus_calls = 0
        # configure() overwrites these with real slint ListModels / values.
        self.language_list: Any = None
        self.language_checked: Any = None
        self.apply_preview_lines: Any = None
        self.language_auto = False
        self.language_summary = ""
        # Device picker state, seeded by configure().
        self.device_list: Any = None
        self.device_index = 0
        self.mod_device = False
        # Bound by configure() at runtime. Declared so mypy sees the callbacks.
        self.clear_transcription: Callable[[], None] = lambda: None
        self.copy_transcription: Callable[[], None] = lambda: None
        self.download_model: Callable[[], None] = lambda: None
        self.transcribe: Callable[[], None] = lambda: None
        self.record: Callable[[], None] = lambda: None
        self.play: Callable[[], None] = lambda: None
        self.seeked: Callable[[float], None] = lambda _f: None
        self.stream: Callable[[], None] = lambda: None
        self.model_changed: Callable[[str], None] = lambda _v: None
        self.device_opened: Callable[[], None] = lambda: None
        self.device_selected: Callable[[int], None] = lambda _i: None
        self.rescan: Callable[[], None] = lambda: None
        self.apply_confirmed: Callable[[], None] = lambda: None
        self.revert_config: Callable[[], None] = lambda: None

    def focus_transcript(self) -> None:
        # Stands in for the .slint public function that focuses the field.
        self.focus_calls += 1


def test_clear_transcription_blanks_field_source_and_timing() -> None:
    win = FakeWindow()
    app.configure(win)

    # Simulate a completed transcribe having populated every surface.
    win.transcription = "And so my fellow Americans, ask not what your country…"
    win.transcription_source = "whisper · small"
    win.transcription_timing = "0.9s"

    win.clear_transcription()

    assert win.transcription == ""
    assert win.transcription_source == ""
    assert win.transcription_timing == ""


def test_clear_transcription_is_idempotent_from_clean_state() -> None:
    # Clearing an already-empty surface must stay empty, never raise: the Clear
    # button is a no-op guard, not a toggle.
    win = FakeWindow()
    app.configure(win)

    win.clear_transcription()

    assert win.transcription == ""
    assert win.transcription_timing == ""


def test_configure_survives_blank_reactive_combo_reads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The startup crash regression. sel-vad-threshold / sel-max-duration are
    # reactive list[index] bindings that read back "" when Python reads them
    # synchronously at configure time, before the combo model settles. That is
    # the exact read the live app makes on its startup path
    # (configure -> refresh_modified -> current_params -> build_params), where a
    # bare float("")/int("") raised ValueError and killed the app before any
    # window showed. Seed the stand-in with the empty reads the real binding
    # yields and assert configure survives, with current_params() producing
    # valid, typed numeric params. This reproduces the crash in the sandbox: a
    # real compiled MainWindow would need the slint-dev headless backend and
    # only ever skip here (see test_lifecycle / test_tooltips).
    seen: list[TranscribeParams] = []

    def spy_build_params(*args: Any, **kwargs: Any) -> TranscribeParams:
        # Route through the real (fixed) coercion and capture what the startup
        # current_params() produced, so the assertion sees the actual numbers.
        # configure() resolves build_params from app's module globals, so the
        # setattr below reroutes it here, and this calls the real one back.
        params = build_params(*args, **kwargs)
        seen.append(params)
        return params

    monkeypatch.setattr(app, "build_params", spy_build_params)

    win = FakeWindow()
    win.sel_vad_threshold = ""  # what the reactive list[index] binding yields
    win.sel_max_duration = ""  # synchronously at startup, before it settles

    app.configure(win)  # pre-fix: raises ValueError here (float(""))

    assert seen, "configure never built params"
    for params in seen:
        assert isinstance(params.vad_threshold, float)
        assert isinstance(params.max_duration, int)
    # The blank reads fell back to the built-in defaults rather than crashing.
    assert seen[-1].vad_threshold == 0.4
    assert seen[-1].max_duration == 60


@pytest.mark.skipif(
    importlib.util.find_spec("slint_dev_native") is None,
    reason="a real MainWindow needs the slint-dev headless backend, absent in "
    "the nix build sandbox (same guard test_lifecycle uses)",
)
def test_real_window_configure_survives_startup_binding_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Belt-and-suspenders over the stand-in test above: exercise the TRUE
    # reactive binding on a compiled MainWindow wherever the dev backend exists
    # (dev venv / MCP). Read synchronously at configure time, exactly the live
    # startup ordering, sel-vad-threshold / sel-max-duration read back before
    # the model settles, so configure must not raise on the coercion.
    monkeypatch.setenv("SLINT_BACKEND", "headless")
    monkeypatch.setenv("SLINT_MCP_PORT", "0")

    components = slint.load_file(str(app.SLINT_FILE))
    instance = components.MainWindow()

    seen: list[TranscribeParams] = []

    def spy_build_params(*args: Any, **kwargs: Any) -> TranscribeParams:
        params = build_params(*args, **kwargs)
        seen.append(params)
        return params

    monkeypatch.setattr(app, "build_params", spy_build_params)

    app.configure(instance)  # must not raise on the real binding read

    assert seen, "configure never built params"
    for params in seen:
        assert isinstance(params.vad_threshold, float)
        assert isinstance(params.max_duration, int)


@pytest.mark.skipif(
    importlib.util.find_spec("slint_dev_native") is None,
    reason="the scheme wiring is reactive, so it needs a real compiled "
    "MainWindow on the slint-dev headless backend (absent in the nix sandbox)",
)
def test_theme_mode_resolves_and_follows_the_os_scheme(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The scheme regression. Palette.color-scheme is a one-way override in Slint
    # (no revert-to-OS), so the titlebar toggle tracks the OS in an os-dark latch
    # and hands Palette back with `unknown` on System. Assert the three
    # invariants the fix restores: System follows the OS (a simulated Palette
    # write), Light/Dark stick regardless of Palette, and returning to System
    # re-follows the OS instead of freezing at the last manual pick.
    dark_scheme = slint.language.ColorScheme.dark
    light_scheme = slint.language.ColorScheme.light
    unknown_scheme = slint.language.ColorScheme.unknown

    monkeypatch.setenv("SLINT_BACKEND", "headless")
    monkeypatch.setenv("SLINT_MCP_PORT", "0")

    components = slint.load_file(str(app.SLINT_FILE))
    instance = components.MainWindow()
    ci = instance.__instance__

    def pump() -> None:
        # The scheme side effects run in `changed` handlers, which fire on a loop
        # iteration, so flush one before every assertion. A single-shot timer
        # quits the loop it just entered.
        timer = slint.Timer()
        timer.start(
            slint.TimerMode.SingleShot,
            datetime.timedelta(milliseconds=15),
            slint.quit_event_loop,
        )
        slint.run_event_loop()

    def set_os(scheme: Any) -> None:
        # A ColorScheme member. Typed Any so this stays clean whether mypy sees
        # the real slint stubs or the merge-gate's slint=Any override.
        ci.set_global_property("Palette", "color-scheme", scheme)
        pump()

    def pick(mode: int) -> None:
        # theme-mode is what the Segmented drives through its two-way binding, so
        # setting it directly is exactly what a tab click does.
        ci.set_property("theme-mode", mode)
        pump()

    def dark() -> bool:
        return bool(ci.get_global_property("Theme", "dark"))

    pump()  # let init seed the latch

    # System (default) follows a simulated OS scheme.
    set_os(dark_scheme)
    assert dark() is True
    set_os(light_scheme)
    assert dark() is False

    # Dark override sticks even when the OS flips underneath it.
    pick(1)
    assert dark() is True
    set_os(light_scheme)
    assert dark() is True
    set_os(unknown_scheme)
    assert dark() is True

    # Light override likewise ignores the OS.
    pick(0)
    assert dark() is False
    set_os(dark_scheme)
    assert dark() is False

    # The exact regression: Dark override, then back to System must re-follow the
    # OS. Entering System hands Palette back with `unknown`, then a concrete OS
    # value drives the scheme again.
    pick(1)
    assert dark() is True
    pick(2)
    assert ci.get_global_property("Palette", "color-scheme") == unknown_scheme
    set_os(dark_scheme)
    assert dark() is True
    set_os(light_scheme)
    assert dark() is False


def test_transcript_field_scrolls_only_when_it_overflows() -> None:
    # The transcript pane is the largest, quietest reading surface in the tuner.
    # It still needs to handle long dictations, but a permanent scrollbar makes
    # short results look like an editor. Keep the custom field inside a
    # ScrollView whose vertical scrollbar is conditional and whose horizontal
    # scrollbar stays off because the transcript wraps by word.
    src = app.SLINT_FILE.read_text()
    transcript_region = src[src.index("transcript-scroll := ScrollView") :]

    assert "transcript-scroll := ScrollView" in transcript_region
    assert "vertical-scrollbar-policy: as-needed;" in transcript_region
    assert "horizontal-scrollbar-policy: always-off;" in transcript_region
    assert "width: transcript-scroll.viewport-width;" in transcript_region
    assert "wrap: word-wrap;" in transcript_region


class _CapturingNative:
    """Stand-in for app.native: captures marshalled callbacks so the test drives
    the "event loop" by draining them, instead of a real Slint loop.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.pending: list[Callable[[], None]] = []

    def invoke_from_event_loop(self, cb: Callable[[], None]) -> None:
        with self._lock:
            self.pending.append(cb)

    def drain(self) -> None:
        with self._lock:
            cbs, self.pending = self.pending, []
        for cb in cbs:
            cb()


def _wait_until(pred: Callable[[], bool], timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return False


def test_copy_puts_the_transcript_on_the_clipboard(
    monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
) -> None:
    # Copy shells out to wl-copy the same way transcribe shells out to voxtype,
    # so point WL_COPY_BIN at a fake that records what it was handed on stdin.
    # The copy runs off the UI thread and marshals its confirmation back, so
    # drive the fake event loop the way the download/transcribe tests do.
    dest = tmp_path / "clipboard.txt"
    fake = tmp_path / "wl-copy"
    fake.write_text(f"#!/usr/bin/env bash\ncat > {dest}\n")
    fake.chmod(0o755)
    monkeypatch.setattr(app, "WL_COPY_BIN", str(fake))

    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    win = FakeWindow()
    app.configure(win)
    win.transcription = "And so my fellow Americans"

    win.copy_transcription()

    assert _wait_until(lambda: len(fake_native.pending) >= 1), "copy never finished"
    fake_native.drain()

    assert dest.read_text() == "And so my fellow Americans"
    assert win.copy_feedback == "ok"


def test_copy_is_a_safe_noop_when_the_transcript_is_empty(
    monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
) -> None:
    # Empty transcript: the button is disabled, and this guard mirrors it, so a
    # synthetic click can never spawn wl-copy, blank the clipboard, or flash the
    # confirmation. A fake that would create a file proves it was never run.
    dest = tmp_path / "clipboard.txt"
    fake = tmp_path / "wl-copy"
    fake.write_text(f"#!/usr/bin/env bash\ntouch {dest}\n")
    fake.chmod(0o755)
    monkeypatch.setattr(app, "WL_COPY_BIN", str(fake))

    win = FakeWindow()
    app.configure(win)
    win.transcription = ""

    win.copy_transcription()

    assert not dest.exists()
    assert win.copy_feedback == ""


def test_second_download_click_is_a_noop_while_one_is_in_flight(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A model fetch is multi-GB with no progress feedback, so users re-click. A
    # second concurrent voxtype download corrupts the model dir. The in-flight
    # guard must make a re-click a complete no-op (no second worker spawned) and
    # only re-allow a download once the first has completed.
    win = FakeWindow()
    win.sel_engine = "parakeet"
    win.sel_model = "parakeet-tdt-0.6b-v3"

    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    calls: list[tuple[str, str]] = []
    entered = threading.Event()
    release = threading.Event()
    downloaded = threading.Event()

    # Availability would be a real filesystem probe. Model it instead: absent
    # until the fake download lands, user afterwards, so the click guard sees
    # something to fetch and the completion reports ready cleanly.
    def fake_availability(_engine: str, _model: str, _system_paths: Any = None) -> Any:
        state = "user" if downloaded.is_set() else "absent"
        return models.ModelAvailability(state=state)  # type: ignore[arg-type]

    monkeypatch.setattr(models, "model_availability", fake_availability)

    def slow_download(
        engine: str,
        model: str,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        on_progress: Any = None,  # noqa: ARG001  app passes it by keyword
        cancel: Any = None,  # noqa: ARG001  app passes it by keyword
    ) -> Any:
        calls.append((engine, model))
        entered.set()
        release.wait(5.0)  # hold the worker so the second click races an active run
        downloaded.set()
        return models.DownloadResult(ok=True, returncode=0, stderr_tail="", error=None)

    monkeypatch.setattr(models, "download_model", slow_download)

    app.configure(win)

    win.download_model()  # click 1: reserves the guard, spawns the worker
    win.download_model()  # click 2: guard set on the UI thread -> no-op

    assert _wait_until(entered.is_set), "first download never started"
    assert len(calls) == 1  # the second click spawned nothing
    assert win.downloading is True

    # Let the first finish and drive its marshalled completion. The guard clears.
    release.set()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.downloading is False
    assert win.model_status == "ready (user download) ✓"
    assert win.model_state == "user"

    # The guard is clear. A re-click on this now-available model is refused by
    # the availability guard instead (nothing left to download), not by the
    # in-flight one.
    entered.clear()
    win.download_model()  # click 3
    assert len(calls) == 1
    assert win.downloading is False

    # A model that is still absent downloads again fine.
    downloaded.clear()
    win.download_model()  # click 4
    assert _wait_until(lambda: len(calls) == 2), (
        "download not re-allowed after completion"
    )
    release.set()


def _ok_result(text: str, duration_s: float = 0.9) -> TranscribeResult:
    return TranscribeResult(
        text=text,
        raw_stdout=text,
        argv=[],
        returncode=0,
        duration_s=duration_s,
        error=None,
    )


def test_transcribe_click_while_running_cancels_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The Transcribe control is the Stop while a run is active (mirroring the
    # Record→Stop relabel): the second click must kill the run, render the
    # distinct "cancelled" caption, and clear the guard so a fresh run can
    # start immediately, while the killed worker's late completion is
    # dropped, never repainting over the cancel.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    calls: list[Any] = []
    entered = threading.Event()
    release = threading.Event()

    def slow_transcribe(
        _wav: str,
        _p: TranscribeParams,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        model_path: str | None = None,  # noqa: ARG001  app passes it by keyword
        cancel: Any = None,
    ) -> TranscribeResult:
        calls.append(cancel)
        entered.set()
        release.wait(5.0)
        if cancel is not None and cancel.cancelled():
            return TranscribeResult(
                text="",
                raw_stdout="",
                argv=[],
                returncode=-15,
                duration_s=0.2,
                error="cancelled",
                cancelled=True,
            )
        return _ok_result("hello world")

    monkeypatch.setattr(app, "transcribe", slow_transcribe)

    app.configure(win)

    win.transcribe()  # click 1: reserves the guard, spawns the worker
    assert win.transcribing is True
    assert _wait_until(entered.is_set), "first transcribe never started"

    win.transcribe()  # click 2: the Stop (cancel, render, release the guard)
    assert win.transcribing is False
    assert win.transcription_timing == "cancelled"
    assert calls[0] is not None
    assert calls[0].cancelled() is True

    # The killed worker finishes late. Its completion must be dropped.
    release.set()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.transcription == ""
    assert win.transcription_timing == "cancelled"
    assert win.transcribing is False

    # A fresh run is allowed immediately after the cancel.
    entered.clear()
    win.transcribe()
    assert win.transcribing is True
    assert _wait_until(lambda: len(calls) == 2), "cancel did not release the guard"
    release.set()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.transcription == "hello world"
    assert win.transcription_timing == "Transcribed in 0.9s"


def test_stop_click_after_natural_completion_is_a_noop(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The race resolved the other way: the completion renders first (UI-thread
    # ordering), so a late Stop click must not fabricate a cancelled state
    # over real results.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    monkeypatch.setattr(app, "transcribe", lambda *_a, **_k: _ok_result("done"))

    app.configure(win)
    win.transcribe()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()  # completion applied
    assert win.transcribing is False
    assert win.transcription == "done"

    win.transcribe()  # not a Stop anymore: starts run 2 (same fake, instant)
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.transcription == "done"
    assert win.transcription_timing == "Transcribed in 0.9s"


def test_transcribe_tags_source_with_engine_and_model(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # With a single take there is no slot to attribute the transcript to. The
    # useful provenance for A/B tuning is which engine/model produced it.
    win = FakeWindow()
    win.sel_engine = "whisper"
    win.sel_model = "small"
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    monkeypatch.setattr(
        app,
        "transcribe",
        lambda *_args, **_kwargs: _ok_result("hi"),
    )

    app.configure(win)
    win.transcribe()

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.transcription_source == "whisper · small"


def test_transcribe_failure_clears_busy_and_timing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    def failing_transcribe(
        _wav: str,
        _p: TranscribeParams,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        model_path: str | None = None,  # noqa: ARG001  app passes it by keyword
        cancel: Any = None,  # noqa: ARG001  app passes it by keyword
    ) -> TranscribeResult:
        return TranscribeResult(
            text="",
            raw_stdout="",
            argv=[],
            returncode=1,
            duration_s=3.0,
            error="voxtype exited with code 1",
        )

    monkeypatch.setattr(app, "transcribe", failing_transcribe)

    app.configure(win)
    win.transcribe()

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.transcribing is False
    assert win.transcription == "transcription failed: voxtype exited with code 1"
    # Timing is meaningful only for a completed run. A failure clears it.
    assert win.transcription_timing == ""


class _CapturingTakeRecorder:
    """Stand-in for wiring.TakeRecorder: captures the hooks configure passes so
    the test can drive state/error notifications like the worker threads do.
    """

    instances: ClassVar[list[_CapturingTakeRecorder]] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.toggles = 0
        _CapturingTakeRecorder.instances.append(self)

    def toggle(self) -> None:
        self.toggles += 1


def test_record_click_toggles_and_state_reaches_the_ui(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakeRecorder.instances = []
    monkeypatch.setattr(app, "TakeRecorder", _CapturingTakeRecorder)

    app.configure(win)
    recorder = _CapturingTakeRecorder.instances[-1]

    win.take_status = "stale error from a previous attempt"
    win.record()
    assert recorder.toggles == 1
    # A fresh attempt must not sit under a stale error message.
    assert win.take_status == ""

    # The worker thread reports capture-started. The marshalled write flips the
    # UI property that relabels the button to Stop.
    recorder.kwargs["on_state"](True)
    fake_native.drain()
    assert win.recording is True

    recorder.kwargs["on_state"](False)
    fake_native.drain()
    assert win.recording is False


def test_recorder_errors_land_in_take_status(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakeRecorder.instances = []
    monkeypatch.setattr(app, "TakeRecorder", _CapturingTakeRecorder)

    app.configure(win)
    recorder = _CapturingTakeRecorder.instances[-1]

    recorder.kwargs["on_error"]("no audio input device available")
    fake_native.drain()
    assert win.take_status == "no audio input device available"


class _CapturingTakePlayer:
    """Stand-in for player.TakePlayer: flips is_playing() the way the real
    toggle does and captures on_finished so the test can fire completion like
    the PortAudio callback thread does, without opening an output device.
    """

    instances: ClassVar[list[_CapturingTakePlayer]] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.toggles: list[str] = []
        self.seeks: list[float] = []
        # Return value of seek(): whether it established a real position. The
        # real player reports this so on_seek only paints a backable fill.
        self.seek_result = True
        self.stops = 0
        self._playing = False
        _CapturingTakePlayer.instances.append(self)

    def toggle(self, path: str) -> None:
        self.toggles.append(path)
        self._playing = not self._playing  # idle->play, playing->pause

    def seek(self, fraction: float) -> bool:
        self.seeks.append(fraction)
        return self.seek_result

    def stop(self) -> None:
        self.stops += 1
        self._playing = False

    def is_playing(self) -> bool:
        return self._playing

    def progress(self) -> float:
        return 0.0


def test_play_click_toggles_playback_and_state_reaches_the_ui(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakePlayer.instances = []
    monkeypatch.setattr(app, "TakePlayer", _CapturingTakePlayer)

    app.configure(win)
    player = _CapturingTakePlayer.instances[-1]

    # First click starts playback: the button flips to Pause via `playing`.
    win.play()
    assert len(player.toggles) == 1
    assert win.playing is True

    # Second click pauses: `playing` returns to Play so the button offers
    # resume, but the fill (playback_progress) is deliberately left frozen.
    win.playback_progress = 0.4
    win.play()
    assert win.playing is False
    assert win.playback_progress == 0.4

    # The take ending on its own fires on_finished from the callback thread. The
    # marshalled write clears the fill and returns the button to Play.
    win.playing = True
    win.playback_progress = 0.9
    player.kwargs["on_finished"]()
    fake_native.drain()
    assert win.playing is False
    assert win.playback_progress == 0.0


def test_play_error_lands_in_take_status(monkeypatch: pytest.MonkeyPatch) -> None:
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    class _BoomPlayer:
        def __init__(self, **_kwargs: Any) -> None:
            pass

        def toggle(self, _path: str) -> None:
            msg = "cannot read recording: absent"
            raise PlayerError(msg)

        def stop(self) -> None:
            pass

        def is_playing(self) -> bool:
            return False

        def progress(self) -> float:
            return 0.0

    monkeypatch.setattr(app, "TakePlayer", _BoomPlayer)
    app.configure(win)

    win.play()
    fake_native.drain()  # show_take_status marshals the error onto the loop
    assert "cannot read recording" in win.take_status
    assert win.playing is False


def test_record_start_stops_running_playback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Starting a take capture must stop any playback: the take is being
    # rewritten, so a running playback clock is stale.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakePlayer.instances = []
    _CapturingTakeRecorder.instances = []
    monkeypatch.setattr(app, "TakePlayer", _CapturingTakePlayer)
    monkeypatch.setattr(app, "TakeRecorder", _CapturingTakeRecorder)

    app.configure(win)
    player = _CapturingTakePlayer.instances[-1]

    win.play()  # playing
    assert win.playing is True

    win.playback_progress = 0.5
    win.record()  # a fresh take must halt playback and clear the fill
    assert player.stops == 1
    assert win.playing is False
    assert win.playback_progress == 0.0


def test_seek_updates_progress_only_when_the_seek_takes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # on_seek must paint the fill (playback_progress) only when the player
    # actually established a position. A no-op seek (nothing to back it up)
    # must leave the fill untouched, so a click never shows a phantom boundary
    # the next Play would snap away.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakePlayer.instances = []
    monkeypatch.setattr(app, "TakePlayer", _CapturingTakePlayer)

    app.configure(win)
    player = _CapturingTakePlayer.instances[-1]

    win.playback_progress = 0.0
    win.seeked(0.4)  # the seek takes, so the fill tracks the pointer
    assert player.seeks == [pytest.approx(0.4)]
    assert win.playback_progress == pytest.approx(0.4)

    player.seek_result = False
    win.seeked(0.7)  # the seek is a no-op, so the fill must not move
    assert win.playback_progress == pytest.approx(0.4)


def test_run_swallows_keyboard_interrupt_so_ctrl_c_is_clean() -> None:
    # Ctrl+C surfaces as a KeyboardInterrupt out of Slint's event loop. The run
    # wrapper must swallow it and return normally (clean exit code, no
    # traceback), not propagate the asyncio crash the user hit.
    ran = threading.Event()

    class InterruptingInstance:
        def run(self) -> None:
            ran.set()
            raise KeyboardInterrupt

    app._run(InterruptingInstance())  # must not raise
    assert ran.is_set()


def test_run_propagates_other_exceptions() -> None:
    # Only Ctrl+C is a clean quit. A real error from the loop must still surface.
    class FailingInstance:
        def run(self) -> None:
            msg = "renderer exploded"
            raise RuntimeError(msg)

    with pytest.raises(RuntimeError, match="renderer exploded"):
        app._run(FailingInstance())


class SeededWindow:
    """Attribute bag that also mirrors MainWindow's two-way bindings.

    The ``sel-*`` read-back properties in app.slint derive from combo
    index/checkbox/text state. Modelling that derivation here lets the tests
    edit a param the way the UI does (move the index, fire the callback) and
    assert what Python recomputes (seeding, live indicators and reset) end
    to end without a window.
    """

    def __init__(self) -> None:
        self.engine_list: Any = None
        self.engine_index = 0
        self.model_list: Any = None
        self.model_index = 0
        self.language_list: Any = None
        self.language_checked: Any = None
        self.language_auto = False
        self.language_summary = ""
        self.vad_threshold_list: Any = None
        self.vad_threshold_index = 1
        self.maxdur_list: Any = None
        self.maxdur_index = 2
        self.vad_checked = True
        self.prompt_text = ""
        self.defaults_status = ""
        self.mod_engine = False
        self.mod_model = False
        self.mod_language = False
        self.mod_prompt = False
        self.mod_vad = False
        self.mod_vad_threshold = False
        self.mod_max_duration = False
        self.mod_streaming = False
        self.mod_device = False
        self.any_modified = False
        self.device_list: Any = None
        self.device_index = 0
        self.model_status = ""
        self.model_state = "absent"
        self.model_status_error = False
        self.take_status = ""
        self.playing = False
        self.playback_progress = 0.0
        self.input_level = 0.0
        self.input_available = True
        self.downloading = False
        self.transcribing = False
        self.recording = False
        self.transcription = ""
        self.transcription_source = ""
        self.transcription_timing = ""
        self.streaming = False
        self.stream_status = ""
        self.stream_visible = False
        self.streaming_available = False
        self.stream_startable = False
        self.param_streaming = False
        self.stream_note = ""
        self.apply_available = False
        self.apply_preview_source = ""
        self.apply_preview_lines: Any = None
        self.apply_status = ""
        self.apply_status_error = False
        self.applying = False
        self.override_exists = False
        self.focus_calls = 0
        # Bound by configure() at runtime. Declared so mypy sees the callbacks.
        self.engine_changed: Callable[[str], None] = lambda _v: None
        self.model_changed: Callable[[str], None] = lambda _v: None
        self.device_opened: Callable[[], None] = lambda: None
        self.device_selected: Callable[[int], None] = lambda _i: None
        self.rescan: Callable[[], None] = lambda: None
        self.download_model: Callable[[], None] = lambda: None
        self.transcribe: Callable[[], None] = lambda: None
        self.param_edited: Callable[[], None] = lambda: None
        self.reset_defaults: Callable[[], None] = lambda: None
        self.language_toggled: Callable[[int], None] = lambda _i: None
        self.language_auto_selected: Callable[[], None] = lambda: None
        self.stream: Callable[[], None] = lambda: None
        self.apply_confirmed: Callable[[], None] = lambda: None
        self.revert_config: Callable[[], None] = lambda: None

    def focus_transcript(self) -> None:
        self.focus_calls += 1

    @property
    def sel_streaming(self) -> bool:
        return self.param_streaming

    @property
    def sel_engine(self) -> str:
        return _row(self.engine_list, self.engine_index)

    @property
    def sel_model(self) -> str:
        if self.model_list.row_count() == 0:
            return ""
        return _row(self.model_list, self.model_index)

    @property
    def sel_prompt(self) -> str:
        return self.prompt_text

    @property
    def sel_vad(self) -> bool:
        return self.vad_checked

    @property
    def sel_vad_threshold(self) -> str:
        return _row(self.vad_threshold_list, self.vad_threshold_index)

    @property
    def sel_max_duration(self) -> str:
        return _row(self.maxdur_list, self.maxdur_index)


def _row(model: Any, index: int) -> str:
    value = model.row_data(index)
    assert isinstance(value, str)
    return value


def _rows(model: Any) -> list[str]:
    return [_row(model, i) for i in range(model.row_count())]


def _checked(win: Any) -> dict[str, bool]:
    codes = _rows(win.language_list)
    return {
        code: bool(win.language_checked.row_data(i)) for i, code in enumerate(codes)
    }


_SEEDED_PARAMS = TranscribeParams(
    engine="whisper",
    model="small",
    language="auto",
    initial_prompt="ahoy there",
    vad=True,
    vad_threshold=0.4,
    max_duration=60,
)


def _startup(
    params: TranscribeParams = _SEEDED_PARAMS,
    initial: TranscribeParams | None = None,
    model_paths: dict[tuple[str, str], str] | None = None,
) -> Any:
    system = defaults.SystemDefaults(
        params=params, loaded=True, status="System defaults: /tmp/fixture.toml"
    )
    return defaults.StartupDefaults(
        system=system,
        initial=initial or params,
        status=system.status,
        model_paths=model_paths or {},
    )


def test_configure_seeds_controls_from_system_defaults() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())

    assert _rows(win.engine_list)[win.engine_index] == "whisper"
    assert _rows(win.model_list)[win.model_index] == "small"
    assert win.language_auto is True
    assert not any(_checked(win).values())
    assert win.language_summary == "Auto"
    assert _rows(win.vad_threshold_list)[win.vad_threshold_index] == "0.40"
    assert _rows(win.maxdur_list)[win.maxdur_index] == "60"
    assert win.vad_checked is True
    assert win.prompt_text == "ahoy there"
    assert win.defaults_status == "System defaults: /tmp/fixture.toml"
    assert win.any_modified is False
    assert (
        win.mod_engine
        or win.mod_model
        or win.mod_language
        or win.mod_prompt
        or win.mod_vad
        or win.mod_vad_threshold
        or win.mod_max_duration
    ) is False


def test_configure_without_defaults_reports_not_found_status() -> None:
    # conftest points $VOXTYPE_TUNER_DEFAULT_CONFIG at a missing file, so the
    # internal load must surface the built-in fallback in the status bar.
    win = SeededWindow()
    app.configure(win)

    assert win.defaults_status == "System defaults: not found, using built-ins"
    assert win.prompt_text == ""
    assert win.any_modified is False


def test_checking_a_language_leaves_auto_and_flips_the_indicator() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())  # seeded language: auto

    de = _rows(win.language_list).index("de")
    win.language_toggled(de)

    assert win.language_auto is False
    assert _checked(win)["de"] is True
    assert win.language_summary == "DE"
    assert win.mod_language is True
    assert win.any_modified is True
    assert win.mod_vad is False  # only the edited param is flagged


def test_unchecking_the_last_language_snaps_back_to_auto() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())

    de = _rows(win.language_list).index("de")
    win.language_toggled(de)
    win.language_toggled(de)

    assert win.language_auto is True
    assert not any(_checked(win).values())
    assert win.language_summary == "Auto"
    assert win.mod_language is False
    assert win.any_modified is False


def test_multi_selection_summary_and_auto_exclusivity() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())

    rows = _rows(win.language_list)
    win.language_toggled(rows.index("en"))
    win.language_toggled(rows.index("de"))

    assert win.language_summary == "EN + DE"
    assert win.language_auto is False

    win.language_toggled(rows.index("fr"))
    assert win.language_summary == "3 languages"

    # Selecting Auto is exclusive: every checkbox clears in the same step so
    # the state can never read as auto+codes.
    win.language_auto_selected()
    assert win.language_auto is True
    assert not any(_checked(win).values())
    assert win.language_summary == "Auto"
    assert win.mod_language is False


# A nemotron system baseline: no tuner model, and its language lives in
# [nemotron].target_lang, so the picker seeds from that (here "de").
_NEMOTRON_SEEDED_PARAMS = TranscribeParams(
    engine="nemotron",
    model="",
    language="de",
    initial_prompt="",
    vad=True,
    vad_threshold=0.4,
    max_duration=60,
)


def test_nemotron_seeded_language_shows_in_pill_and_checklist() -> None:
    # The seed side of the round-trip: a nemotron system whose target_lang maps
    # to "de" starts the picker with DE checked and the pill reading "DE".
    win = SeededWindow()
    app.configure(win, startup=_startup(_NEMOTRON_SEEDED_PARAMS))

    assert win.sel_engine == "nemotron"
    assert win.language_auto is False
    assert _checked(win)["de"] is True
    assert win.language_summary == "DE"
    assert win.any_modified is False


def test_nemotron_language_is_single_select() -> None:
    # Nemotron is single-target: checking a second language replaces the first
    # rather than accumulating like whisper's multi-select.
    win = SeededWindow()
    app.configure(win, startup=_startup(_NEMOTRON_SEEDED_PARAMS))

    rows = _rows(win.language_list)
    win.language_toggled(rows.index("fr"))

    checked = _checked(win)
    assert checked["fr"] is True
    assert checked["de"] is False
    assert win.language_summary == "FR"
    assert win.language_auto is False


def test_nemotron_language_uncheck_snaps_to_auto() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup(_NEMOTRON_SEEDED_PARAMS))

    de = _rows(win.language_list).index("de")
    win.language_toggled(de)  # uncheck the only selection

    assert win.language_auto is True
    assert not any(_checked(win).values())
    assert win.language_summary == "Auto"


def test_engine_switch_to_nemotron_normalizes_multi_language_to_auto() -> None:
    # A whisper multi-selection carried into nemotron has no single-target
    # meaning (nemotron_target_lang would send "auto"), so the pill must not keep
    # advertising it: entering nemotron normalizes it to Auto.
    win = SeededWindow()
    app.configure(win, startup=_startup())

    rows = _rows(win.language_list)
    win.language_toggled(rows.index("en"))
    win.language_toggled(rows.index("de"))
    assert win.language_summary == "EN + DE"

    win.engine_index = _rows(win.engine_list).index("nemotron")
    win.engine_changed("nemotron")

    assert win.language_auto is True
    assert not any(_checked(win).values())
    assert win.language_summary == "Auto"


def test_engine_switch_to_nemotron_keeps_a_single_mappable_language() -> None:
    # A single curated code IS a valid nemotron target, so entering nemotron
    # leaves it selected rather than needlessly resetting to Auto.
    win = SeededWindow()
    app.configure(win, startup=_startup())

    rows = _rows(win.language_list)
    win.language_toggled(rows.index("de"))

    win.engine_index = _rows(win.engine_list).index("nemotron")
    win.engine_changed("nemotron")

    assert win.language_auto is False
    assert _checked(win)["de"] is True
    assert win.language_summary == "DE"


def test_editing_a_param_flips_its_indicator_and_back() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())

    win.vad_checked = False
    win.param_edited()

    assert win.mod_vad is True
    assert win.any_modified is True
    assert win.mod_language is False  # only the edited param is flagged

    win.vad_checked = True
    win.param_edited()

    assert win.mod_vad is False
    assert win.any_modified is False


def test_engine_roundtrip_restores_seeded_model_catalog() -> None:
    # A custom (store-path) default model must survive switching the engine
    # away and back: the catalog is rebuilt with the custom entry appended and
    # the default re-selected, so the indicator turns back off.
    path = "/nix/store/abc123-ggml-house-style.bin"
    win = SeededWindow()
    app.configure(win, startup=_startup(replace(_SEEDED_PARAMS, model=path)))

    assert _rows(win.model_list)[win.model_index] == path

    win.engine_index = 1
    win.engine_changed("parakeet")

    assert path not in _rows(win.model_list)
    assert win.model_index == 0
    assert win.mod_engine is True
    assert win.mod_model is True

    win.engine_index = 0
    win.engine_changed("whisper")

    assert _rows(win.model_list)[win.model_index] == path
    assert win.mod_engine is False
    assert win.mod_model is False
    assert win.any_modified is False


def test_reset_defaults_restores_seeded_state_and_clears_flags() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())

    win.engine_index = 1
    win.engine_changed("parakeet")
    win.vad_checked = False
    win.prompt_text = "scribbled over"
    win.param_edited()
    win.language_toggled(_rows(win.language_list).index("fr"))
    assert win.any_modified is True

    win.reset_defaults()

    assert _rows(win.engine_list)[win.engine_index] == "whisper"
    assert _rows(win.model_list)[win.model_index] == "small"
    assert win.language_auto is True
    assert not any(_checked(win).values())
    assert win.language_summary == "Auto"
    assert win.vad_checked is True
    assert win.prompt_text == "ahoy there"
    assert win.any_modified is False
    assert win.mod_engine is False
    assert win.mod_model is False
    assert win.mod_language is False
    assert win.mod_vad is False
    assert win.mod_prompt is False


def test_configure_starts_at_user_config_with_indicators_lit() -> None:
    # A user who already applied overrides sees their CURRENT settings on
    # launch, with the dots lit for exactly what differs from the baseline,
    # and Reset immediately available to go back to system defaults.
    initial = replace(
        _SEEDED_PARAMS,
        model="base.en",
        language="en,de",
        vad=False,
        initial_prompt="",
    )
    win = SeededWindow()
    app.configure(win, startup=_startup(initial=initial))

    assert _rows(win.model_list)[win.model_index] == "base.en"
    assert win.language_auto is False
    checked = _checked(win)
    assert checked["en"] is True
    assert checked["de"] is True
    assert win.language_summary == "EN + DE"
    assert win.vad_checked is False
    assert win.prompt_text == ""
    assert win.mod_model is True
    assert win.mod_language is True
    assert win.mod_vad is True
    assert win.mod_prompt is True
    assert win.mod_engine is False
    assert win.mod_vad_threshold is False
    assert win.any_modified is True


def test_reset_from_user_config_returns_to_baseline() -> None:
    initial = replace(_SEEDED_PARAMS, model="base.en", vad=False)
    win = SeededWindow()
    app.configure(win, startup=_startup(initial=initial))

    win.reset_defaults()

    assert _rows(win.model_list)[win.model_index] == "small"
    # the user's model stays selectable after reset, the catalog is stable
    assert "base.en" in _rows(win.model_list)
    assert win.vad_checked is True
    assert win.any_modified is False
    assert win.mod_model is False
    assert win.mod_vad is False


def test_model_status_distinguishes_system_user_and_absent(
    tmp_path: pathlib.Path,
) -> None:
    # The headline three-state honesty: a system-provisioned store-path model
    # must read "ready (system)", never "not downloaded", and switching to a
    # model nobody provides must say so IMMEDIATELY, via the same
    # selection-change path that already refreshes the caption.
    weights = tmp_path / "fake-store" / "abc123-ggml-small.bin"
    weights.parent.mkdir()
    weights.write_bytes(b"ggml")
    win = SeededWindow()
    app.configure(
        win,
        startup=_startup(model_paths={("whisper", "small"): str(weights)}),
    )

    # Seeded selection is the system model.
    assert win.model_status == "ready (system) ✓"
    assert win.model_state == "system"

    # An absent catalog model: flips on the model-changed callback.
    win.model_index = _rows(win.model_list).index("tiny")
    win.model_changed("tiny")
    assert win.model_status == "not downloaded"
    assert win.model_state == "absent"

    # A user-dir download of that same model flips it to the user caption.
    root = pathlib.Path(models.models_dir())
    root.mkdir(parents=True)
    (root / "ggml-tiny.bin").write_bytes(b"ggml")
    win.model_changed("tiny")
    assert win.model_status == "ready (user download) ✓"
    assert win.model_state == "user"


def test_engine_switch_refreshes_model_state_immediately(
    tmp_path: pathlib.Path,
) -> None:
    # Flipping the engine re-derives the status for the NEW engine's default
    # model in the same callback, no interaction with the model combo needed.
    model_dir = tmp_path / "abc123-parakeet-unified-en-0.6b"
    model_dir.mkdir()
    win = SeededWindow()
    app.configure(
        win,
        startup=_startup(
            model_paths={("parakeet", "parakeet-unified-en-0.6b"): str(model_dir)}
        ),
    )
    assert win.model_state == "absent"  # whisper small: nothing on disk

    win.engine_index = 1
    win.engine_changed("parakeet")

    # parakeet's catalog default lands on the seeded selection (index 0,
    # no parakeet default in the baseline), an absent model...
    assert win.model_state == "absent"

    # ...but selecting the system-provisioned one reads system instantly.
    win.model_index = _rows(win.model_list).index("parakeet-unified-en-0.6b")
    win.model_changed("parakeet-unified-en-0.6b")
    assert win.model_status == "ready (system) ✓"
    assert win.model_state == "system"


def test_transcribe_passes_system_model_path_through(
    monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
) -> None:
    # A "ready (system)" model has no user-dir copy. Transcribing it by name
    # would fail (or silently run base.en). The wiring must hand the resolved
    # absolute path to transcribe so it routes through the generated config.
    weights = tmp_path / "abc123-ggml-small.bin"
    weights.write_bytes(b"ggml")
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    seen: list[str | None] = []

    def capturing_transcribe(
        _wav: str,
        _p: TranscribeParams,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        model_path: str | None = None,
        cancel: Any = None,  # noqa: ARG001  app passes it by keyword
    ) -> TranscribeResult:
        seen.append(model_path)
        return _ok_result("hi")

    monkeypatch.setattr(app, "transcribe", capturing_transcribe)

    app.configure(
        win, startup=_startup(model_paths={("whisper", "small"): str(weights)})
    )

    win.transcribe()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert seen == [str(weights)]

    # A name-resolvable (absent or user) model transcribes by name: no pin.
    win.model_index = _rows(win.model_list).index("tiny")
    win.model_changed("tiny")
    win.transcribe()
    assert _wait_until(lambda: len(seen) == 2)
    assert seen[1] is None


def test_transcribe_nemotron_pins_provisioned_model_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Nemotron has no tuner catalog and always probes "absent", so its model can
    # never arrive via the availability path. The wiring must hand transcribe the
    # Nix-provisioned model dir from the environment instead, so it lands in the
    # generated [nemotron] config rather than transcribing nothing.
    monkeypatch.setattr(app, "VOXTYPE_NEMOTRON_MODEL", "/nix/store/x-nemotron-model")
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    seen: list[str | None] = []

    def capturing_transcribe(
        _wav: str,
        _p: TranscribeParams,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        model_path: str | None = None,
        cancel: Any = None,  # noqa: ARG001  app passes it by keyword
    ) -> TranscribeResult:
        seen.append(model_path)
        return _ok_result("ask not")

    monkeypatch.setattr(app, "transcribe", capturing_transcribe)
    app.configure(win, startup=_startup())

    win.engine_index = _rows(win.engine_list).index("nemotron")
    win.engine_changed("nemotron")
    win.transcribe()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert seen == ["/nix/store/x-nemotron-model"]


def test_download_progress_reaches_the_status_caption(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The worker hands download_model an on_progress hook. Every sample must
    # land in the caption via the event-loop marshal, replacing the initial
    # bare "downloading…" with live numbers.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    def fake_download(
        _engine: str,
        _model: str,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        on_progress: Callable[[models.DownloadProgress], None] | None = None,
        cancel: Any = None,  # noqa: ARG001  app passes it by keyword
    ) -> models.DownloadResult:
        assert on_progress is not None
        on_progress(models.DownloadProgress(done_bytes=0, total_bytes=1000))
        on_progress(models.DownloadProgress(done_bytes=450, total_bytes=1000))
        return models.DownloadResult(ok=False, returncode=1, stderr_tail="", error="x")

    monkeypatch.setattr(models, "download_model", fake_download)

    app.configure(win)
    win.download_model()
    assert win.model_status == "downloading…"

    assert _wait_until(lambda: len(fake_native.pending) >= 3)  # 2 samples + apply
    with fake_native._lock:
        pending = list(fake_native.pending)
        fake_native.pending = []
    pending[0]()
    assert win.model_status == "downloading… 0%"
    pending[1]()
    assert win.model_status == "downloading… 45%"
    for cb in pending[2:]:
        cb()


def test_download_progress_never_overwrites_the_completion_caption(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Marshalled progress writes are ordered before the completion apply, but
    # the guard must hold even if a straggler drains late: once downloading is
    # cleared, a stale "downloading…" may not replace ready/failed.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    hooks: list[Callable[[models.DownloadProgress], None]] = []

    def fake_download(
        _engine: str,
        _model: str,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        on_progress: Callable[[models.DownloadProgress], None] | None = None,
        cancel: Any = None,  # noqa: ARG001  app passes it by keyword
    ) -> models.DownloadResult:
        assert on_progress is not None
        hooks.append(on_progress)
        return models.DownloadResult(ok=False, returncode=1, stderr_tail="", error="x")

    monkeypatch.setattr(models, "download_model", fake_download)

    app.configure(win)
    win.download_model()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()  # completion applied: failed caption, downloading off
    assert win.downloading is False
    failed_caption = win.model_status

    hooks[0](models.DownloadProgress(done_bytes=500, total_bytes=1000))
    fake_native.drain()

    assert win.model_status == failed_caption


def test_download_failure_flags_the_caption_as_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # "failed: …" must be visibly distinct (destructive color via the flag),
    # and the flag must clear on the next selection-driven refresh so an old
    # failure never tints a fresh model's status.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    monkeypatch.setattr(
        models,
        "download_model",
        lambda *_args, **_kwargs: models.DownloadResult(
            ok=False, returncode=1, stderr_tail="boom", error="boom"
        ),
    )

    app.configure(win)
    assert win.model_status_error is False

    win.download_model()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.model_status == "failed: boom"
    assert win.model_status_error is True

    win.model_changed("tiny")
    assert win.model_status_error is False
    assert win.model_status == "not downloaded"


def test_download_click_is_a_noop_for_an_available_model(
    monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
) -> None:
    # The Download button is disabled for user/system models in the UI. The
    # Python guard must mirror that so a synthetic invocation can't spawn a
    # pointless (and dir-corrupting) re-fetch.
    weights = tmp_path / "abc123-ggml-small.bin"
    weights.write_bytes(b"ggml")
    win = SeededWindow()

    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        models,
        "download_model",
        lambda *args, **_kwargs: calls.append((args[0], args[1])),
    )

    app.configure(
        win, startup=_startup(model_paths={("whisper", "small"): str(weights)})
    )
    assert win.model_state == "system"

    win.download_model()

    assert calls == []
    assert win.downloading is False


def test_streaming_gate_follows_the_selection() -> None:
    # Streaming affordances are engine- and model-gated: the Stream control
    # exists only for parakeet (stream_visible) and is usable only for the
    # allowlisted streaming-capable model (streaming_available), tracking
    # every selection change through the same refresh as the model status.
    win = SeededWindow()
    app.configure(win, startup=_startup())  # seeded: whisper · small

    assert win.stream_visible is False
    assert win.streaming_available is False

    win.engine_index = 1
    win.engine_changed("parakeet")
    # visible for parakeet, but the catalog default cannot stream: hint state.
    assert win.stream_visible is True
    assert win.streaming_available is False

    win.model_index = _rows(win.model_list).index("parakeet-unified-en-0.6b")
    win.model_changed("parakeet-unified-en-0.6b")
    assert win.streaming_available is True

    win.engine_index = 0
    win.engine_changed("whisper")
    assert win.stream_visible is False
    assert win.streaming_available is False


def test_streaming_gate_covers_nemotron() -> None:
    # Nemotron streams too: the Stream control is visible and streaming is
    # available for it (its one provisioned model always streams, no per-model
    # gate), and switching back to whisper hides it. Parakeet's
    # allowlisted-model gating (covered above) is untouched.
    win = SeededWindow()
    app.configure(win, startup=_startup())  # seeded: whisper · small

    win.engine_index = _rows(win.engine_list).index("nemotron")
    win.engine_changed("nemotron")
    assert win.stream_visible is True
    assert win.streaming_available is True

    win.engine_index = _rows(win.engine_list).index("whisper")
    win.engine_changed("whisper")
    assert win.stream_visible is False
    assert win.streaming_available is False


def _select_streaming_capable(win: SeededWindow) -> None:
    win.engine_index = 1
    win.engine_changed("parakeet")
    win.model_index = _rows(win.model_list).index("parakeet-unified-en-0.6b")
    win.model_changed("parakeet-unified-en-0.6b")


class _CapturingStreamSession:
    """Stand-in for streaming.StreamSession: records the wiring's calls and
    hands the marshalled callbacks to the test to fire like worker threads do.
    """

    instances: ClassVar[list[_CapturingStreamSession]] = []

    def __init__(self, p: TranscribeParams, **kwargs: Any) -> None:
        self.p = p
        self.kwargs = kwargs
        self.started = 0
        self.stops = 0
        self.reaps = 0
        _CapturingStreamSession.instances.append(self)

    def start(self) -> None:
        self.started += 1

    def stop(self) -> None:
        self.stops += 1

    def reap(self) -> None:
        self.reaps += 1


def _streaming_ready(
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[SeededWindow, _CapturingNative]:
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingStreamSession.instances = []
    monkeypatch.setattr(streaming, "StreamSession", _CapturingStreamSession)
    monkeypatch.setattr(
        models,
        "model_availability",
        lambda *_a, **_k: models.ModelAvailability(
            state="system", path="/nix/store/x-parakeet-unified-en-0.6b"
        ),
    )
    app.configure(win, startup=_startup())
    _select_streaming_capable(win)
    return win, fake_native


def _nemotron_streaming_ready(
    monkeypatch: pytest.MonkeyPatch,
) -> tuple[SeededWindow, _CapturingNative]:
    # Deliberately does NOT monkeypatch model_availability: nemotron always
    # probes "absent" (no on-disk catalog), and the whole point is that the
    # session starts anyway, driven off the provisioned env path.
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    monkeypatch.setattr(app, "VOXTYPE_NEMOTRON_MODEL", "/nix/store/x-nemotron-model")
    _CapturingStreamSession.instances = []
    monkeypatch.setattr(streaming, "StreamSession", _CapturingStreamSession)
    app.configure(win, startup=_startup())
    win.engine_index = _rows(win.engine_list).index("nemotron")
    win.engine_changed("nemotron")
    return win, fake_native


def test_stream_click_nemotron_uses_provisioned_model_and_does_not_early_return(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Nemotron always probes "absent", so the parakeet bytes-gate would refuse
    # it. The wiring must instead pin the Nix-provisioned model path and never
    # early-return. on_done provenance names just the engine (no model select).
    win, fake_native = _nemotron_streaming_ready(monkeypatch)

    win.stream()
    assert win.streaming is True
    assert len(_CapturingStreamSession.instances) == 1
    session = _CapturingStreamSession.instances[-1]
    assert session.started == 1
    assert session.p.engine == "nemotron"
    assert session.kwargs["model_path"] == "/nix/store/x-nemotron-model"

    session.kwargs["on_live"]()
    fake_native.drain()
    assert win.stream_status == "streaming…"
    assert win.focus_calls == 1

    win.stream()  # Stop
    assert session.stops == 1

    session.kwargs["on_done"](
        streaming.StreamOutcome(
            ok=True, error=None, session_s=4.2, finalize_s=0.3, hit_max_duration=False
        )
    )
    fake_native.drain()
    assert win.streaming is False
    assert win.transcription_source == "nemotron · streamed (typed)"
    assert win.transcription_timing == "Streamed 4.2s · finalized in 0.3s"


def test_stream_click_runs_the_session_lifecycle(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win, fake_native = _streaming_ready(monkeypatch)

    win.stream()
    assert win.streaming is True
    assert win.stream_status == "starting voxtype daemon…"
    # The incoming stream types into a clean field.
    assert win.transcription == ""
    assert win.transcription_timing == ""

    session = _CapturingStreamSession.instances[-1]
    assert session.started == 1
    # The session got the streaming-capable params and the system model path.
    assert session.p.model == "parakeet-unified-en-0.6b"
    assert session.kwargs["model_path"] == "/nix/store/x-parakeet-unified-en-0.6b"

    # Live: caption flips and the transcript field takes focus so the typed
    # stream lands in the tuner.
    session.kwargs["on_live"]()
    fake_native.drain()
    assert win.stream_status == "streaming…"
    assert win.focus_calls == 1

    session.kwargs["on_tick"](3.2)
    fake_native.drain()
    assert win.stream_status == "streaming… 3.2s"

    # Second click is the Stop: finalize, never a second session.
    win.stream()
    assert session.stops == 1
    assert win.stream_status == "finalizing…"
    assert len(_CapturingStreamSession.instances) == 1

    session.kwargs["on_done"](
        streaming.StreamOutcome(
            ok=True, error=None, session_s=5.6, finalize_s=0.4, hit_max_duration=False
        )
    )
    fake_native.drain()
    assert win.streaming is False
    assert win.stream_status == ""
    assert (
        win.transcription_source
        == "parakeet · parakeet-unified-en-0.6b · streamed (typed)"
    )
    assert win.transcription_timing == "Streamed 5.6s · finalized in 0.4s"


def test_stream_done_at_the_cap_shows_max_duration_caption(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win, fake_native = _streaming_ready(monkeypatch)
    win.stream()
    session = _CapturingStreamSession.instances[-1]

    session.kwargs["on_done"](
        streaming.StreamOutcome(
            ok=True, error=None, session_s=60.2, finalize_s=None, hit_max_duration=True
        )
    )
    fake_native.drain()
    assert win.transcription_timing == "Streamed 60.2s · reached max duration"


def test_stream_failure_lands_in_take_status(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A dead daemon is a distinct, worded failure, surfaced beside the
    # Stream control (destructive caption), never a hang and never fake
    # timing numbers.
    win, fake_native = _streaming_ready(monkeypatch)
    win.stream()
    session = _CapturingStreamSession.instances[-1]

    session.kwargs["on_done"](
        streaming.StreamOutcome(
            ok=False,
            error="voxtype daemon exited (code -9)",
            session_s=0.0,
            finalize_s=None,
            hit_max_duration=False,
        )
    )
    fake_native.drain()
    assert win.streaming is False
    assert win.take_status == "streaming failed: voxtype daemon exited (code -9)"
    assert win.transcription_timing == ""


def test_stream_tick_never_overwrites_the_finalizing_caption(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A tick marshalled before the Stop click drains after it: the caption
    # must deterministically stay "finalizing…" (last writer is the stop).
    win, fake_native = _streaming_ready(monkeypatch)
    win.stream()
    session = _CapturingStreamSession.instances[-1]
    session.kwargs["on_live"]()
    fake_native.drain()

    session.kwargs["on_tick"](4.0)  # queued, not yet drained
    win.stream()  # Stop
    assert win.stream_status == "finalizing…"
    fake_native.drain()  # the stale tick applies now, and must be ignored
    assert win.stream_status == "finalizing…"


def test_stream_click_refused_without_capability_or_bytes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The Python guard mirrors the disabled control: no session for a
    # non-capable selection, and none for a capable one without bytes.
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingStreamSession.instances = []
    monkeypatch.setattr(streaming, "StreamSession", _CapturingStreamSession)
    app.configure(win, startup=_startup())

    win.stream()  # whisper: not even visible
    assert _CapturingStreamSession.instances == []

    _select_streaming_capable(win)  # capable, but absent (no bytes anywhere)
    assert win.streaming_available is True
    win.stream()
    assert _CapturingStreamSession.instances == []
    assert win.streaming is False


def test_selection_change_reaps_an_active_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Model switch, engine switch and Reset all invalidate the running
    # scratch daemon's config: the session is reaped and the streaming UI
    # state resets, with no late repaint from the dead session.
    win, _fake_native = _streaming_ready(monkeypatch)
    win.stream()
    session = _CapturingStreamSession.instances[-1]

    win.model_index = _rows(win.model_list).index("parakeet-tdt-0.6b-v3")
    win.model_changed("parakeet-tdt-0.6b-v3")

    assert session.reaps == 1
    assert win.streaming is False
    assert win.stream_status == ""
    assert win.streaming_available is False


def test_reset_defaults_reaps_an_active_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win, _fake_native = _streaming_ready(monkeypatch)
    win.stream()
    session = _CapturingStreamSession.instances[-1]

    win.reset_defaults()

    assert session.reaps == 1
    assert win.streaming is False


def test_run_reaps_streaming_on_every_exit_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The terminal-lifecycle contract: Ctrl-C/SIGTERM/Ctrl-D quit the event
    # loop and _run returns, the reap hook behind it must fire on the normal
    # return, the KeyboardInterrupt fallback, and even a crashing loop, so a
    # scratch daemon can never outlive the tuner.
    reaps: list[int] = []
    monkeypatch.setattr(streaming, "reap_active", lambda: reaps.append(1))

    class CleanInstance:
        def run(self) -> None:
            return

    class InterruptingInstance:
        def run(self) -> None:
            raise KeyboardInterrupt

    class ExplodingInstance:
        def run(self) -> None:
            msg = "renderer exploded"
            raise RuntimeError(msg)

    app._run(CleanInstance())
    assert len(reaps) == 1
    app._run(InterruptingInstance())
    assert len(reaps) == 2
    with pytest.raises(RuntimeError, match="renderer exploded"):
        app._run(ExplodingInstance())
    assert len(reaps) == 3


def test_transcribe_caption_carries_rtfx_for_a_readable_take(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The batch caption's RTFx comes from the take's WAV header against the
    # measured wall-clock, end to end through the wiring, not just the
    # metrics helper.

    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    monkeypatch.setattr(
        app, "transcribe", lambda *_a, **_k: _ok_result("hi", duration_s=0.5)
    )

    wav_path = pathlib.Path(slots.take_wav_path())
    with wave.open(str(wav_path), "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(16000)
        fh.writeframes(b"\x00\x00" * 16000)  # 1.0s of audio

    app.configure(win)
    win.transcribe()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.transcription_timing == "Transcribed in 0.5s · 2.0x realtime"


def _cancellable_download_fixture(
    monkeypatch: pytest.MonkeyPatch,
    *,
    result_when_cancelled: bool = True,
    hold: threading.Event | None = None,
    availability: dict[str, str] | None = None,
) -> tuple[FakeWindow, _CapturingNative, list[tuple[str, str]], threading.Event]:
    """Wire a FakeWindow to a fake download that honours its CancelHandle.

    The fake blocks like a real multi-GB fetch until its handle reports
    cancelled (or 5s), then reports cancelled. With
    ``result_when_cancelled=False`` it reports a clean completion even though
    cancel was requested, modelling the kill losing the race to a natural
    exit (rc 0 → the artifact is complete, so download_model reports ok).
    ``hold``, when given, keeps the worker alive after the cancel so a test
    can inject progress samples into the "cancelling…" window.
    ``availability`` is a mutable holder: its "state" key is what every
    model_availability probe reports, so a test can flip it mid-flight.
    """
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    calls: list[tuple[str, str]] = []
    entered = threading.Event()
    avail = availability if availability is not None else {"state": "absent"}

    def fake_availability(*_args: Any, **_kwargs: Any) -> models.ModelAvailability:
        return models.ModelAvailability(state=avail["state"])  # type: ignore[arg-type]

    monkeypatch.setattr(models, "model_availability", fake_availability)

    def fake_download(
        engine: str,
        model: str,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        on_progress: Any = None,  # noqa: ARG001  app passes it by keyword
        cancel: Any = None,
    ) -> models.DownloadResult:
        calls.append((engine, model))
        entered.set()
        assert cancel is not None, "app must hand download_model its cancel handle"
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and not cancel.cancelled():
            time.sleep(0.01)
        if hold is not None:
            hold.wait(5.0)
        if cancel.cancelled() and result_when_cancelled:
            return models.DownloadResult(
                ok=False,
                returncode=-15,
                stderr_tail="",
                error="cancelled",
                cancelled=True,
            )
        return models.DownloadResult(ok=True, returncode=0, stderr_tail="", error=None)

    monkeypatch.setattr(models, "download_model", fake_download)
    app.configure(win)
    return win, fake_native, calls, entered


def test_stop_click_cancels_clears_busy_and_reallows_download(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The Download button relabels to Stop while a fetch runs (Record→Stop
    # precedent), so a click during `downloading` is a cancel request routed
    # through the same callback. Cancelling must clear the single-flight guard
    # so a new download can start immediately, and the caption must land on a
    # distinct cancelled state, probe-derived, not the failure caption.
    win, fake_native, calls, entered = _cancellable_download_fixture(monkeypatch)

    win.download_model()  # click 1: idle → start
    assert win.downloading is True
    assert _wait_until(entered.is_set), "download never started"

    win.download_model()  # click 2: running → this is the Stop action
    assert win.model_status == "cancelling…"

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.downloading is False
    assert win.model_status == "cancelled, not downloaded"
    assert win.model_status_error is False
    assert win.model_state == "absent"

    # The guard is clear: the very next click starts a fresh download.
    entered.clear()
    win.download_model()
    assert _wait_until(lambda: len(calls) == 2), "re-download not allowed after cancel"
    assert win.downloading is True
    win.download_model()  # stop it again so the worker exits before teardown
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.downloading is False


def test_progress_after_stop_click_never_overwrites_cancelling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Between the Stop click and the worker's completion the poller is still
    # sampling a (dying) subprocess. Those samples must not repaint fake
    # progress over the "cancelling…" caption.
    hold = threading.Event()
    win, fake_native, _calls, entered = _cancellable_download_fixture(
        monkeypatch, hold=hold
    )
    hooks: list[Any] = []
    orig_download = models.download_model

    def capture_hook(*args: Any, **kwargs: Any) -> models.DownloadResult:
        hooks.append(kwargs["on_progress"])
        return orig_download(*args, **kwargs)

    monkeypatch.setattr(models, "download_model", capture_hook)

    win.download_model()
    assert _wait_until(entered.is_set)
    win.download_model()  # Stop: cancel requested, worker held open by `hold`
    assert win.model_status == "cancelling…"

    hooks[0](models.DownloadProgress(done_bytes=500, total_bytes=1000))
    fake_native.drain()
    assert win.model_status == "cancelling…"

    hold.set()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()
    assert win.model_status == "cancelled, not downloaded"


def test_cancel_losing_the_race_to_completion_renders_completed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A Stop click whose kill lands after the subprocess already exited
    # cleanly must render as a completed download (exactly one of
    # {completed, cancelled}) and never claim a cancel that didn't happen.
    avail = {"state": "absent"}
    win, fake_native, _calls, entered = _cancellable_download_fixture(
        monkeypatch, result_when_cancelled=False, availability=avail
    )

    win.download_model()
    assert _wait_until(entered.is_set)
    win.download_model()  # Stop click, but the fake completes anyway
    # The "download" landed, so the completion probe must now report it and
    # re-derive the ready caption from it.
    avail["state"] = "user"

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.downloading is False
    assert win.model_status == "ready (user download) ✓"
    assert win.model_state == "user"
    assert win.model_status_error is False


def test_stop_click_when_idle_is_a_noop(monkeypatch: pytest.MonkeyPatch) -> None:
    # With no download in flight there is nothing to cancel: the availability
    # guard already refused the click, and no "cancelling…" caption may appear.
    avail = {"state": "absent"}
    win, _fake_native, calls, _entered = _cancellable_download_fixture(
        monkeypatch, availability=avail
    )
    avail["state"] = "user"  # nothing to fetch → the click must be refused

    win.download_model()

    assert calls == []
    assert win.downloading is False
    assert win.model_status != "cancelling…"


def test_cancel_caption_names_the_cancelled_model_not_the_new_selection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The selection can move while a cancel is still tearing down. The
    # completion must caption the CANCELLED fetch's own (absent) state. A
    # "cancelled, ready ✓" hybrid built from the new selection's probe would
    # pin the cancel on a model it never touched. The button state, by
    # contrast, keeps following the current selection.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    entered = threading.Event()

    def fake_availability(
        _engine: str, model: str, _system_paths: Any = None
    ) -> models.ModelAvailability:
        # tiny (the download about to be cancelled) is absent, base.en (where
        # the selection moves mid-cancel) is already downloaded.
        state = "user" if model == "base.en" else "absent"
        return models.ModelAvailability(state=state)  # type: ignore[arg-type]

    monkeypatch.setattr(models, "model_availability", fake_availability)

    def fake_download(
        _engine: str,
        _model: str,
        voxtype_bin: str = "voxtype",  # noqa: ARG001  app passes it by keyword
        on_progress: Any = None,  # noqa: ARG001  app passes it by keyword
        cancel: Any = None,
    ) -> models.DownloadResult:
        entered.set()
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and not cancel.cancelled():
            time.sleep(0.01)
        return models.DownloadResult(
            ok=False, returncode=-15, stderr_tail="", error="cancelled", cancelled=True
        )

    monkeypatch.setattr(models, "download_model", fake_download)
    app.configure(win)

    win.download_model()  # starts fetching tiny
    assert _wait_until(entered.is_set)
    win.download_model()  # Stop
    win.sel_model = "base.en"  # selection moves before the teardown finishes
    win.model_changed("base.en")
    assert win.model_status == "ready (user download) ✓"

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.downloading is False
    assert win.model_status == "cancelled, not downloaded"  # about tiny
    assert win.model_state == "user"  # the button still tracks base.en
    assert win.model_status_error is False


_STREAMING_PARAMS = TranscribeParams(
    engine="parakeet",
    model="parakeet-unified-en-0.6b",
    language="en",
    initial_prompt="",
    vad=True,
    vad_threshold=0.4,
    max_duration=60,
    streaming=True,
)


def test_streaming_param_seeds_and_gates_on_capability() -> None:
    # A streaming parakeet baseline seeds the toggle on. The checkbox is usable
    # (streaming_available) because the model is capable.
    win = SeededWindow()
    app.configure(win, startup=_startup(_STREAMING_PARAMS))

    assert win.param_streaming is True
    assert win.streaming_available is True
    assert win.mod_streaming is False  # matches the baseline


def test_streaming_param_snaps_off_when_model_loses_capability() -> None:
    # Switching to a non-capable parakeet model must snap the toggle OFF (the
    # daemon refuses streaming there) and word the flip, mirroring the language
    # snap-back so the state can never go invalid.
    win = SeededWindow()
    app.configure(win, startup=_startup(_STREAMING_PARAMS))
    assert win.param_streaming is True

    win.model_index = _rows(win.model_list).index("parakeet-tdt-0.6b-v3")
    win.model_changed("parakeet-tdt-0.6b-v3")

    assert win.param_streaming is False
    assert win.streaming_available is False
    assert win.stream_note != ""  # the snap is explained, not silent
    assert win.mod_streaming is True  # off now differs from the on baseline


def test_streaming_param_snaps_off_on_engine_switch_to_whisper() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup(_STREAMING_PARAMS))

    win.engine_index = 0
    win.engine_changed("whisper")

    assert win.param_streaming is False
    assert win.streaming_available is False


def test_streaming_param_toggle_flips_modified_and_apply() -> None:
    # Toggling the capable model's streaming off is a real param edit: the dot
    # lights and Apply becomes available (it now differs from the effective).
    win = SeededWindow()
    app.configure(win, startup=_startup(_STREAMING_PARAMS))
    assert win.apply_available is False  # seeded == effective

    win.param_streaming = False
    win.param_edited()

    assert win.mod_streaming is True
    assert win.apply_available is True


_NEMOTRON_STREAMING_PARAMS = TranscribeParams(
    engine="nemotron",
    # Nemotron has no tuner model selection, so its seeded model is empty.
    model="",
    language="auto",
    initial_prompt="",
    vad=True,
    vad_threshold=0.4,
    max_duration=60,
    streaming=True,
)


def test_streaming_param_seeds_on_for_nemotron() -> None:
    # A nemotron streaming baseline seeds the toggle on. The checkbox is usable
    # (streaming_available) because nemotron can always stream, and the empty
    # model catalog does not spuriously light the modified dot.
    win = SeededWindow()
    app.configure(win, startup=_startup(_NEMOTRON_STREAMING_PARAMS))

    assert win.param_streaming is True
    assert win.streaming_available is True
    assert win.mod_streaming is False  # matches the baseline
    assert win.any_modified is False


def test_streaming_param_snaps_off_on_engine_switch_nemotron_to_whisper() -> None:
    # Switching nemotron→whisper drops streaming capability, so the toggle snaps
    # OFF with a worded note, the same never-invalid invariant as parakeet.
    win = SeededWindow()
    app.configure(win, startup=_startup(_NEMOTRON_STREAMING_PARAMS))
    assert win.param_streaming is True

    win.engine_index = _rows(win.engine_list).index("whisper")
    win.engine_changed("whisper")

    assert win.param_streaming is False
    assert win.streaming_available is False
    assert win.stream_note != ""
    assert win.mod_streaming is True  # off now differs from the on baseline


def test_streaming_param_toggle_flips_modified_and_apply_for_nemotron() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup(_NEMOTRON_STREAMING_PARAMS))
    assert win.apply_available is False  # seeded == effective

    win.param_streaming = False
    win.param_edited()

    assert win.mod_streaming is True
    assert win.apply_available is True


def test_apply_preview_lists_changes_against_effective() -> None:
    win = SeededWindow()
    app.configure(win, startup=_startup())  # whisper · small, no override
    assert win.apply_available is False
    assert win.apply_preview_source == "the system defaults"

    win.vad_checked = False
    win.param_edited()

    assert win.apply_available is True
    lines = _rows(win.apply_preview_lines)
    assert "VAD: on → off" in lines


def test_apply_preview_diffs_against_the_user_override_when_present() -> None:
    # With an override on disk (at the conftest-pinned XDG_CONFIG_HOME), the
    # effective config is that override: the preview diffs against it and names
    # it, not the system baseline.
    config = pathlib.Path(defaults.user_config_path())
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('engine = "whisper"\n[whisper]\nmodel = "base.en"\n')

    win = SeededWindow()
    # initial (effective) = the override's base.en, baseline stays small.
    initial = replace(_SEEDED_PARAMS, model="base.en", vad=False)
    app.configure(win, startup=_startup(initial=initial))

    assert win.override_exists is True
    assert win.apply_preview_source == "your current config"
    # Params start AT the override, so nothing to apply.
    assert win.apply_available is False

    # Editing away from the override lights Apply, diffed against the override.
    win.vad_checked = True
    win.param_edited()
    assert win.apply_available is True


def _fake_apply(
    monkeypatch: pytest.MonkeyPatch, outcome: apply.ApplyOutcome
) -> tuple[SeededWindow, _CapturingNative, list[Any]]:
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    calls: list[Any] = []

    def fake_apply_config(
        p: TranscribeParams,
        _baseline: Any,
        _model_paths: Any,
        config_path: str,
        systemctl_bin: str,
        nemotron_model: str | None = None,  # noqa: ARG001  app passes it by keyword
    ) -> apply.ApplyOutcome:
        calls.append((p, config_path, systemctl_bin))
        return outcome

    monkeypatch.setattr(apply, "apply_config", fake_apply_config)
    app.configure(win, startup=_startup())
    return win, fake_native, calls


def test_apply_confirmed_reports_success_and_advances_effective(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    outcome = apply.ApplyOutcome(
        ok=True, kind="applied", message="applied, daemon restarted"
    )
    win, fake_native, calls = _fake_apply(monkeypatch, outcome)

    win.vad_checked = False
    win.param_edited()
    assert win.apply_available is True

    win.apply_confirmed()
    assert win.applying is True
    assert win.apply_status == "applying…"

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.applying is False
    assert win.apply_status == "applied, daemon restarted"
    assert win.apply_status_error is False
    assert win.override_exists is True
    # The daemon now runs these params: re-applying them has nothing to do,
    # even though the modified dot (vs the system baseline) stays lit.
    assert win.apply_available is False
    assert win.mod_vad is True
    assert len(calls) == 1
    # The snapshot handed to apply reflects the edit.
    assert calls[0][0].vad is False


def test_apply_restart_failure_keeps_override_and_words_the_note(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    outcome = apply.ApplyOutcome(
        ok=False,
        kind="restart_failed",
        message="wrote config, but daemon restart failed: boom. Fix or remove /p",
    )
    win, fake_native, _calls = _fake_apply(monkeypatch, outcome)

    win.vad_checked = False
    win.param_edited()
    win.apply_confirmed()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.apply_status_error is True
    assert "restart failed" in win.apply_status
    # The written override is on disk: Revert stays offered as the escape hatch,
    # and Apply stays available so the restart can be retried.
    assert win.override_exists is True
    assert win.apply_available is True


def test_apply_write_failure_leaves_state_untouched(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    outcome = apply.ApplyOutcome(
        ok=False, kind="write_failed", message="apply failed: could not write /p: x"
    )
    win, fake_native, _calls = _fake_apply(monkeypatch, outcome)

    win.vad_checked = False
    win.param_edited()
    win.apply_confirmed()
    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.apply_status_error is True
    assert win.override_exists is False  # nothing was written


def test_revert_reports_outcome_and_returns_to_baseline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win = SeededWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    calls: list[Any] = []

    def fake_revert(config_path: str, systemctl_bin: str) -> apply.ApplyOutcome:
        calls.append((config_path, systemctl_bin))
        return apply.ApplyOutcome(
            ok=True,
            kind="reverted",
            message="reverted to system defaults, daemon restarted",
        )

    monkeypatch.setattr(apply, "revert_config", fake_revert)
    # Start as if an override exists so Revert is meaningful.
    initial = replace(_SEEDED_PARAMS, vad=False)
    app.configure(win, startup=_startup(initial=initial))

    win.revert_config()
    assert win.applying is True
    assert win.apply_status == "reverting…"

    assert _wait_until(lambda: len(fake_native.pending) >= 1)
    fake_native.drain()

    assert win.applying is False
    assert win.apply_status == "reverted to system defaults, daemon restarted"
    assert win.override_exists is False
    assert len(calls) == 1


# --- device picker: seed, select, re-enumerate, reset, capture ----------------


def _two_devices() -> list[InputDevice]:
    # System default plus one hardware mic at PortAudio index 5.
    return [
        SYSTEM_DEFAULT,
        InputDevice(label="USB Mic", index=5, voxtype_device="USB Mic"),
    ]


def _no_input() -> list[InputDevice]:
    # A host with no recording input: enumeration yields just the synthetic
    # System-default row, so has_input_device / the wiring read "no microphone".
    return [SYSTEM_DEFAULT]


def test_configure_seeds_device_selection_from_startup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    win = SeededWindow()
    # Both layers pin the USB mic, so it seeds selected with no modified dot.
    startup = _startup(params=replace(_SEEDED_PARAMS, device="USB Mic"))
    app.configure(win, startup=startup)

    assert _rows(win.device_list) == ["System default", "USB Mic"]
    assert win.device_index == 1
    assert win.mod_device is False
    assert win.any_modified is False


def test_device_override_differing_from_baseline_lights_the_dot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    win = SeededWindow()
    # System baseline is the default input, the user's config pins the USB mic.
    startup = _startup(
        params=_SEEDED_PARAMS, initial=replace(_SEEDED_PARAMS, device="USB Mic")
    )
    app.configure(win, startup=startup)

    assert win.device_index == 1
    assert win.mod_device is True
    assert win.any_modified is True


def test_selecting_a_device_flips_the_dot_and_apply_preview(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    win = SeededWindow()
    app.configure(win, startup=_startup())  # baseline + initial: system default

    assert win.device_index == 0
    assert win.mod_device is False

    win.device_selected(1)

    assert win.device_index == 1
    assert win.mod_device is True
    assert win.any_modified is True
    # The choice reaches the Apply preview as a real change to write.
    assert win.apply_available is True
    assert any(line.startswith("Device:") for line in _rows(win.apply_preview_lines))


def test_opening_the_picker_reenumerates_and_keeps_the_selection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    state: dict[str, list[InputDevice]] = {"rows": _two_devices()}
    monkeypatch.setattr(app, "enumerate_input_devices", lambda: list(state["rows"]))
    # Opening the picker rescans (re-inits PortAudio, then re-enumerates). The
    # fake enumerate already returns the post-plug list, so the re-init is a
    # no-op stand-in that must not touch the real audio system.
    monkeypatch.setattr(app, "reinitialize_portaudio", lambda: None)
    win = SeededWindow()
    app.configure(win, startup=_startup())
    win.device_selected(1)  # USB Mic
    assert win.device_index == 1

    # A second mic is plugged in. Opening the picker must surface it while
    # keeping the current selection pinned by label.
    state["rows"] = [
        *_two_devices(),
        InputDevice(label="Webcam Mic", index=7, voxtype_device="Webcam Mic"),
    ]
    win.device_opened()

    assert _rows(win.device_list) == ["System default", "USB Mic", "Webcam Mic"]
    assert win.device_index == 1


def test_opening_the_picker_after_the_only_mic_vanishes_shows_no_microphone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    state: dict[str, list[InputDevice]] = {"rows": _two_devices()}
    monkeypatch.setattr(app, "enumerate_input_devices", lambda: list(state["rows"]))
    monkeypatch.setattr(app, "reinitialize_portaudio", lambda: None)
    win = SeededWindow()
    app.configure(win, startup=_startup())
    win.device_selected(1)

    # The only mic is unplugged: the rescan on the next open finds no input, so
    # the picker collapses to the placeholder and input-available flips off.
    state["rows"] = [SYSTEM_DEFAULT]
    win.device_opened()

    assert _rows(win.device_list) == ["No microphone detected"]
    assert win.device_index == 0
    assert win.input_available is False


def test_reset_restores_the_baseline_device(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    win = SeededWindow()
    app.configure(win, startup=_startup())  # baseline: system default
    win.device_selected(1)
    assert win.device_index == 1

    win.reset_defaults()

    assert win.device_index == 0
    assert win.mod_device is False


def test_record_captures_from_the_selected_device_index(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakeRecorder.instances = []
    monkeypatch.setattr(app, "TakeRecorder", _CapturingTakeRecorder)

    app.configure(win)
    recorder = _CapturingTakeRecorder.instances[-1]
    device_for = recorder.kwargs["device_for"]

    # System default selected: Record opens PortAudio's own default (None).
    assert device_for() is None

    win.device_selected(1)
    # The picked row's PortAudio index now reaches the capture call.
    assert device_for() == 5


def test_device_change_reaps_an_active_stream_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    win, _fake_native = _streaming_ready(monkeypatch)
    win.stream()
    session = _CapturingStreamSession.instances[-1]

    win.device_selected(1)

    assert session.reaps == 1
    assert win.streaming is False


# --- input meter: single-owner device policy ----------------------------------


class _CapturingInputMeter:
    """Stand-in for wiring.InputMeter: records the transitions the wiring drives
    (start/stop/pause/resume/retap and the device-lost degrade), and the hooks
    configure passed it.
    """

    instances: ClassVar[list[_CapturingInputMeter]] = []

    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs
        self.events: list[str] = []
        _CapturingInputMeter.instances.append(self)

    def start(self) -> None:
        self.events.append("start")

    def stop(self) -> None:
        self.events.append("stop")

    def pause(self) -> None:
        self.events.append("pause")

    def resume(self) -> None:
        self.events.append("resume")

    def retap(self) -> None:
        self.events.append("retap")

    def handle_device_lost(self) -> None:
        self.events.append("handle_device_lost")


def _with_capturing_meter(monkeypatch: pytest.MonkeyPatch) -> None:
    _CapturingInputMeter.instances = []
    monkeypatch.setattr(app, "InputMeter", _CapturingInputMeter)


def test_meter_taps_the_selected_device_accessor(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The meter must read the SAME accessor Record does, so the bar always
    # shows the device the picker shows.
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    _with_capturing_meter(monkeypatch)
    win = FakeWindow()

    app.configure(win)
    meter = _CapturingInputMeter.instances[-1]
    device_for = meter.kwargs["device_for"]

    assert device_for() is None  # system default
    win.device_selected(1)
    assert device_for() == 5  # the USB mic's PortAudio index


def test_meter_pauses_before_record_and_resumes_when_capture_stops(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakeRecorder.instances = []
    monkeypatch.setattr(app, "TakeRecorder", _CapturingTakeRecorder)
    _with_capturing_meter(monkeypatch)

    app.configure(win)
    meter = _CapturingInputMeter.instances[-1]
    recorder = _CapturingTakeRecorder.instances[-1]

    win.record()
    # The meter yields the mic before the recorder is toggled to open it.
    assert meter.events == ["pause"]
    assert recorder.toggles == 1

    # Capture actually started: the meter stays paused (no resume on True).
    recorder.kwargs["on_state"](True)
    fake_native.drain()
    assert meter.events == ["pause"]

    # Capture stopped: the mic is free again, so the meter resumes.
    recorder.kwargs["on_state"](False)
    fake_native.drain()
    assert meter.events == ["pause", "resume"]


def test_meter_resumes_after_a_failed_record_start(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A Record start that fails to open the device reports on_error but never
    # fires on_state(False), so the meter must resume from the error path too:
    # the mic was never actually taken.
    win = FakeWindow()
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _CapturingTakeRecorder.instances = []
    monkeypatch.setattr(app, "TakeRecorder", _CapturingTakeRecorder)
    _with_capturing_meter(monkeypatch)

    app.configure(win)
    meter = _CapturingInputMeter.instances[-1]
    recorder = _CapturingTakeRecorder.instances[-1]

    win.record()
    assert meter.events == ["pause"]

    recorder.kwargs["on_error"]("no audio input device available")
    fake_native.drain()
    assert meter.events == ["pause", "resume"]
    assert win.take_status == "no audio input device available"


def test_meter_retaps_on_device_change_and_reset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    _with_capturing_meter(monkeypatch)
    win = SeededWindow()

    app.configure(win, startup=_startup())
    meter = _CapturingInputMeter.instances[-1]

    win.device_selected(1)
    assert meter.events == ["retap"]

    win.reset_defaults()
    # Reset re-selects the baseline device, so it re-taps the meter too.
    assert meter.events == ["retap", "retap"]


def test_meter_paused_for_the_whole_stream_session_and_resumed_on_done(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _with_capturing_meter(monkeypatch)
    win, fake_native = _streaming_ready(monkeypatch)
    meter = _CapturingInputMeter.instances[-1]

    win.stream()
    # The scratch daemon owns the mic for the session.
    assert meter.events[-1] == "pause"

    session = _CapturingStreamSession.instances[-1]
    session.kwargs["on_done"](
        streaming.StreamOutcome(
            ok=True, error=None, session_s=4.2, finalize_s=0.3, hit_max_duration=False
        )
    )
    fake_native.drain()
    # The session released the mic, so the idle meter reclaims it.
    assert meter.events[-1] == "resume"


def test_meter_resumed_when_a_selection_change_reaps_a_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _with_capturing_meter(monkeypatch)
    win, _fake_native = _streaming_ready(monkeypatch)
    meter = _CapturingInputMeter.instances[-1]

    win.stream()
    assert meter.events[-1] == "pause"

    # A model switch reaps the running session, which frees the mic.
    win.model_index = _rows(win.model_list).index("parakeet-tdt-0.6b-v3")
    win.model_changed("parakeet-tdt-0.6b-v3")
    assert meter.events[-1] == "resume"


def test_run_stops_the_meter_on_every_exit_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The teardown contract: like the streaming reap, the meter's open capture
    # stream must be closed on the normal return, the KeyboardInterrupt
    # fallback, and even a crashing loop, so no stream outlives the tuner.
    monkeypatch.setattr(streaming, "reap_active", lambda: None)

    class _Inner:
        def __init__(self) -> None:
            self.stopped = False

        def stop(self) -> None:
            self.stopped = True

        def close(self) -> None:
            self.stopped = True

    def _started() -> tuple[InputMeter, _Inner]:
        # A real InputMeter holding a fake capture stream, so _run's teardown is
        # exercised end to end (stop closes the underlying stream).
        inner = _Inner()
        meter = InputMeter(
            on_level=lambda _v: None,
            open_fn=lambda _d, _c, _l: MeterStream(inner),
        )
        meter.start()
        assert inner.stopped is False
        return meter, inner

    class CleanInstance:
        def run(self) -> None:
            return

    class InterruptingInstance:
        def run(self) -> None:
            raise KeyboardInterrupt

    class ExplodingInstance:
        def run(self) -> None:
            msg = "renderer exploded"
            raise RuntimeError(msg)

    meter, inner = _started()
    app._run(CleanInstance(), meter)
    assert inner.stopped is True

    meter, inner = _started()
    app._run(InterruptingInstance(), meter)
    assert inner.stopped is True

    meter, inner = _started()
    with pytest.raises(RuntimeError, match="renderer exploded"):
        app._run(ExplodingInstance(), meter)
    assert inner.stopped is True


class _ExclusiveInputStreams:
    """Fake ``sd.InputStream`` factory modelling ALSA ``hw:`` exclusivity.

    A device is reserved at open and freed at stop/close. A second open on a
    device already held raises PortAudioError, exactly as a real exclusive PCM
    would, so a test can prove the meter yielded the device before Record took
    it (rather than the two silently coexisting, which fakes would otherwise
    allow).
    """

    def __init__(self) -> None:
        self.open_devices: dict[int | None, _ExclusiveInputStreams._Stream] = {}

    def __call__(self, **kwargs: Any) -> _ExclusiveInputStreams._Stream:
        device = kwargs.get("device")
        if device in self.open_devices:
            msg = f"device {device} is busy"
            raise sd.PortAudioError(msg)
        stream = _ExclusiveInputStreams._Stream(device, self, kwargs)
        self.open_devices[device] = stream
        return stream

    class _Stream:
        def __init__(
            self,
            device: int | None,
            owner: _ExclusiveInputStreams,
            kwargs: dict[str, Any],
        ) -> None:
            self.device = device
            self.owner = owner
            self.kwargs = kwargs
            self.callback = kwargs["callback"]

        def start(self) -> None:
            pass

        def stop(self) -> None:
            self.owner.open_devices.pop(self.device, None)

        def close(self) -> None:
            self.owner.open_devices.pop(self.device, None)


def test_record_gets_the_device_after_the_meter_held_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # End-to-end no-clobber, exercised with the REAL meter and recorder over a
    # device-exclusive fake stream: the idle meter holds the mic, and Record
    # must still open it because on_record yields the meter's stream first. If
    # it did not, the second open on the same device would raise and the take
    # would carry a RecorderError instead of a WAV.
    factory = _ExclusiveInputStreams()
    monkeypatch.setattr(sd, "InputStream", factory)
    # The meter now opens only when the host reports an input device, so present
    # one (the system-default row still opens PortAudio's own default = None).
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    # Run the recorder's start/stop worker inline so the sequence is
    # deterministic (the meter release, then the capture open, then the write).
    monkeypatch.setattr(app, "_run_bg", lambda work: work())
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)

    win = FakeWindow()
    meter, _player = app.configure(win)
    meter.start()  # the meter now holds the (system default) device
    assert None in factory.open_devices

    win.record()  # on_record: meter yields the mic, then capture opens it
    assert win.take_status == ""  # no RecorderError: the open succeeded
    assert None in factory.open_devices  # the capture stream now holds it

    # Feed a block so the finalized WAV carries real audio, then stop.
    capture = factory.open_devices[None]
    tone = 0.3 * 32767 * np.sin(np.linspace(0.0, 2 * np.pi, 512))
    block = tone.astype(np.int16).reshape(-1, 1)
    capture.callback(block, len(block), None, None)

    win.record()  # Stop: writes the take
    wav = pathlib.Path(slots.take_wav_path())
    assert wav.exists()
    assert wav.stat().st_size > 44  # more than a bare WAV header: audio landed


# --- no microphone: startup detection, hotplug rescan, and removal ------------


def test_configure_marks_input_unavailable_and_skips_the_meter_open(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A host with no recording input: the picker collapses to the placeholder,
    # input-available flips off (dimming the meter / disabling Record), and the
    # meter's availability gate reports no input, so open_meter_stream is never
    # reached at all (the specific PortAudio-open ALSA stderr never prints).
    monkeypatch.setattr(app, "enumerate_input_devices", _no_input)
    _with_capturing_meter(monkeypatch)
    win = FakeWindow()

    app.configure(win)

    assert win.input_available is False
    assert _rows(win.device_list) == ["No microphone detected"]
    meter = _CapturingInputMeter.instances[-1]
    assert meter.kwargs["available_fn"]() is False


def test_configure_marks_input_available_when_a_mic_exists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    _with_capturing_meter(monkeypatch)
    win = FakeWindow()

    app.configure(win)

    assert win.input_available is True
    assert _rows(win.device_list) == ["System default", "USB Mic"]
    meter = _CapturingInputMeter.instances[-1]
    assert meter.kwargs["available_fn"]() is True


def test_rescan_finds_a_hotplugged_mic_and_rearms(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Start with no input. A rescan re-inits PortAudio (modelled here by the
    # fake re-init flipping the visible device list, exactly as a real re-init
    # rebuilds PortAudio's cached catalog), so the newly plugged mic appears:
    # the picker populates, input-available flips True, and the meter re-arms.
    state: dict[str, list[InputDevice]] = {"rows": _no_input()}
    monkeypatch.setattr(app, "enumerate_input_devices", lambda: list(state["rows"]))

    def fake_reinit() -> None:
        state["rows"] = _two_devices()

    monkeypatch.setattr(app, "reinitialize_portaudio", fake_reinit)
    _with_capturing_meter(monkeypatch)
    win = FakeWindow()

    app.configure(win)
    assert win.input_available is False
    meter = _CapturingInputMeter.instances[-1]

    win.rescan()

    assert win.input_available is True
    assert _rows(win.device_list) == ["System default", "USB Mic"]
    # The rescan closed the idle meter around the re-init and reopened it, so it
    # re-arms on the fresh PortAudio instance.
    assert meter.events == ["pause", "resume"]


def test_rescan_is_a_noop_while_a_stream_is_active(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Re-initialising PortAudio tears down every stream, so a rescan MUST NOT
    # fire while a recording or stream session owns the mic.
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    reinits: list[int] = []
    monkeypatch.setattr(app, "reinitialize_portaudio", lambda: reinits.append(1))
    _with_capturing_meter(monkeypatch)
    win = FakeWindow()

    app.configure(win)
    meter = _CapturingInputMeter.instances[-1]

    win.streaming = True
    win.rescan()
    assert reinits == []
    assert meter.events == []

    win.streaming = False
    win.recording = True
    win.rescan()
    assert reinits == []
    assert meter.events == []


def test_meter_device_loss_degrades_to_no_microphone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The tapped device is unplugged mid-capture: the meter's on_lost fires on
    # the PortAudio callback thread. Marshalled onto the UI thread it must
    # degrade cleanly to the no-microphone state without crashing.
    monkeypatch.setattr(app, "enumerate_input_devices", _two_devices)
    fake_native = _CapturingNative()
    monkeypatch.setattr(app, "native", fake_native)
    _with_capturing_meter(monkeypatch)
    win = FakeWindow()

    app.configure(win)
    assert win.input_available is True
    meter = _CapturingInputMeter.instances[-1]

    # Fire the loss hook configure passed the meter (the callback calls this
    # when the device vanishes).
    meter.kwargs["on_lost"]()
    fake_native.drain()

    assert win.input_available is False
    assert _rows(win.device_list) == ["No microphone detected"]
    assert "handle_device_lost" in meter.events
