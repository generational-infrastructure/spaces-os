"""Meter tests: the pure level math and the fake-driven stream lifecycle.

Two layers, both driven without a real audio device (this host has none):

- the level math (``peak_level`` / ``rms_level`` / ``LevelMeter``): fed
  synthetic int16 buffers (silence, full scale, a 440 Hz sine) to lock the
  normalization and the fast-attack/slow-release smoothing curve.
- the stream lifecycle: ``open_meter_stream`` driven by ``FakeInputStream``
  (the recorder test's stand-in), and the ``InputMeter`` controller driven by a
  fake open function, so the single-owner open/close policy is deterministic.
"""

from typing import Any, ClassVar

import numpy as np
import numpy.typing as npt
import pytest
import sounddevice as sd
from voxtype_tuner.meter import (
    LevelMeter,
    MeterStream,
    open_meter_stream,
    peak_level,
    rms_level,
)
from voxtype_tuner.wiring import InputMeter


def _const_int16(value: int, frames: int = 512) -> npt.NDArray[np.int16]:
    return np.full((frames, 1), value, dtype=np.int16)


def _sine_int16(samplerate: int = 16000, seconds: float = 0.1) -> npt.NDArray[np.int16]:
    t = np.linspace(0.0, seconds, int(samplerate * seconds), endpoint=False)
    samples = 0.5 * np.sin(2 * np.pi * 440.0 * t)
    return (samples * 32767).astype(np.int16).reshape(-1, 1)


# --- level math ---------------------------------------------------------------


def test_peak_level_silence_is_zero() -> None:
    assert peak_level(_const_int16(0)) == 0.0


def test_peak_level_full_scale_is_one() -> None:
    # int16 minimum (-32768): abs must widen to int32 or it wraps to itself,
    # which would read as full scale by accident rather than by design.
    assert peak_level(_const_int16(-32768)) == 1.0
    # The positive maximum lands just under 1.0 (there are 32768 negative but
    # only 32767 positive int16 codes).
    assert peak_level(_const_int16(32767)) == pytest.approx(32767 / 32768)


def test_peak_level_of_a_half_scale_sine() -> None:
    # A 0.5-amplitude sine peaks at ~0.5 of full scale.
    assert peak_level(_sine_int16()) == pytest.approx(0.5, abs=0.01)


def test_rms_level_silence_is_zero() -> None:
    assert rms_level(_const_int16(0)) == 0.0


def test_rms_level_full_scale_is_one() -> None:
    assert rms_level(_const_int16(32767)) == pytest.approx(32767 / 32768)


def test_rms_level_of_a_sine_is_peak_over_root_two() -> None:
    # RMS of a sine is its amplitude / sqrt(2), so a 0.5-amplitude sine is
    # ~0.3536 normalized, distinctly below its 0.5 peak.
    assert rms_level(_sine_int16()) == pytest.approx(0.5 / np.sqrt(2), abs=0.01)


def test_empty_block_reads_zero_for_both_measures() -> None:
    empty = np.zeros((0, 1), dtype=np.int16)
    assert peak_level(empty) == 0.0
    assert rms_level(empty) == 0.0


def test_level_meter_fast_attack_then_slow_release() -> None:
    # A louder block snaps the level up instantly. Silence then decays it by the
    # release factor per block, and the next loud block snaps it straight back.
    meter = LevelMeter(decay=0.86)
    loud = _const_int16(32767)
    silence = _const_int16(0)

    attacked = meter.push(loud)
    assert attacked == pytest.approx(32767 / 32768)

    after_one = meter.push(silence)
    assert after_one == pytest.approx(attacked * 0.86, abs=1e-6)
    after_two = meter.push(silence)
    assert after_two == pytest.approx(attacked * 0.86**2, abs=1e-6)
    assert after_two < after_one  # release keeps falling

    reattacked = meter.push(loud)
    assert reattacked == pytest.approx(32767 / 32768)
    assert reattacked > after_two  # attack is instant, not smoothed


def test_level_meter_honours_the_level_fn_strategy() -> None:
    # The same block reads lower through RMS than through peak, so a meter built
    # on rms_level tracks the quieter measure.
    peak_meter = LevelMeter(level_fn=peak_level)
    rms_meter = LevelMeter(level_fn=rms_level)
    sine = _sine_int16()
    assert rms_meter.push(sine) < peak_meter.push(sine)


# --- stream lifecycle: open_meter_stream --------------------------------------


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


def test_open_meter_stream_opens_16k_mono_int16_on_the_given_index(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    stream = open_meter_stream(5, lambda _v: None)
    assert isinstance(stream, MeterStream)
    opened = FakeInputStream.instances[-1]
    assert opened.kwargs["device"] == 5
    assert opened.kwargs["samplerate"] == 16000
    assert opened.kwargs["channels"] == 1
    assert opened.kwargs["dtype"] == "int16"
    assert opened.kwargs["blocksize"] == 512
    assert opened.started is True


def test_open_meter_stream_defaults_device_to_none(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    open_meter_stream(None, lambda _v: None)
    assert FakeInputStream.instances[-1].kwargs["device"] is None


def test_open_meter_stream_pushes_throttled_levels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The callback fires per block, but only every push_every-th one reaches the
    # sink, so the UI update rate stays calm.
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    pushed: list[float] = []
    open_meter_stream(None, pushed.append, push_every=2)
    stream = FakeInputStream.instances[-1]

    loud = _const_int16(32767)
    stream.callback(loud, len(loud), None, None)
    assert pushed == []  # block 1: below the throttle
    stream.callback(loud, len(loud), None, None)
    assert len(pushed) == 1  # block 2: pushed
    assert pushed[-1] == pytest.approx(32767 / 32768)
    stream.callback(loud, len(loud), None, None)
    stream.callback(loud, len(loud), None, None)
    assert len(pushed) == 2  # block 4: pushed


def test_open_meter_stream_degrades_to_none_without_a_device(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A meter is cosmetic, so a no-device host must get a flat/zero meter, never
    # an error: open returns None instead of raising.
    def _boom(**_kwargs: Any) -> None:
        msg = "no default input device"
        raise sd.PortAudioError(msg)

    monkeypatch.setattr(sd, "InputStream", _boom)
    assert open_meter_stream(None, lambda _v: None) is None


def test_meter_stream_stop_halts_and_closes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    stream = open_meter_stream(None, lambda _v: None)
    assert stream is not None
    stream.stop()
    opened = FakeInputStream.instances[-1]
    assert opened.stopped is True
    assert opened.closed is True


def test_meter_stream_stop_swallows_teardown_errors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A teardown hiccup must not surface in the UI: the device is being yielded
    # regardless, and the meter has nothing to finalize.
    class ExplodingStop(FakeInputStream):
        def stop(self) -> None:
            msg = "device vanished mid-teardown"
            raise sd.PortAudioError(msg)

    monkeypatch.setattr(sd, "InputStream", ExplodingStop)
    stream = open_meter_stream(None, lambda _v: None)
    assert stream is not None
    stream.stop()  # must not raise


def test_open_meter_stream_signals_loss_when_the_callback_errors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A device unplugged mid-stream makes the metering callback fail. That error
    # must be caught (never escape into PortAudio's C stack), the loss signalled
    # once through on_lost, and any trailing callbacks swallowed.
    monkeypatch.setattr(sd, "InputStream", FakeInputStream)
    lost: list[int] = []

    def boom_level(_v: float) -> None:
        msg = "device vanished mid-stream"
        raise RuntimeError(msg)

    stream = open_meter_stream(None, boom_level, lambda: lost.append(1), push_every=1)
    assert stream is not None
    fake = FakeInputStream.instances[-1]

    loud = _const_int16(32767)
    fake.callback(loud, len(loud), None, None)  # must not raise
    assert lost == [1]
    # A trailing callback after the loss is swallowed, not re-signalled.
    fake.callback(loud, len(loud), None, None)
    assert lost == [1]


# --- controller: InputMeter ---------------------------------------------------


class _FakeInner:
    """A fake ``sd.InputStream`` wrapped by a real MeterStream, so the harness
    tracks stop/close through the production teardown path.
    """

    def __init__(self) -> None:
        self.stopped = False
        self.closed = False

    def stop(self) -> None:
        self.stopped = True

    def close(self) -> None:
        self.closed = True


class _MeterHarness:
    """Wires an InputMeter to a fake open function and a recording sink."""

    def __init__(self, device: int | None = None) -> None:
        self.device = device
        self.opens: list[int | None] = []
        self.inners: list[_FakeInner] = []
        self.levels: list[float] = []
        self.meter = InputMeter(
            on_level=self.levels.append,
            device_for=lambda: self.device,
            open_fn=self._open,
        )

    def _open(
        self, device: int | None, _on_level: Any, _on_lost: Any = None
    ) -> MeterStream:
        self.opens.append(device)
        inner = _FakeInner()
        self.inners.append(inner)
        return MeterStream(inner)


def test_input_meter_starts_on_the_selected_device() -> None:
    h = _MeterHarness(device=7)
    h.meter.start()
    assert h.opens == [7]
    # A second start does not stack a second stream on the device.
    h.meter.start()
    assert h.opens == [7]


def test_input_meter_opens_nothing_until_started() -> None:
    # A meter that was never started touches no audio, so resume/retap are inert
    # (this is what keeps every headless test off the mic).
    h = _MeterHarness(device=1)
    h.meter.resume()
    h.meter.retap()
    assert h.opens == []


def test_input_meter_pause_closes_then_resume_reopens() -> None:
    h = _MeterHarness(device=1)
    h.meter.start()
    assert len(h.inners) == 1

    h.meter.pause()
    assert h.inners[0].stopped is True  # yields the device synchronously

    h.meter.resume()
    assert len(h.inners) == 2  # reclaimed the device
    assert h.opens == [1, 1]


def test_input_meter_stop_closes_and_blocks_further_opens() -> None:
    h = _MeterHarness(device=1)
    h.meter.start()
    h.meter.stop()
    assert h.inners[0].stopped is True
    # After a terminal stop, a stray resume must not reopen.
    h.meter.resume()
    assert len(h.inners) == 1


def test_input_meter_retap_reopens_on_the_new_device() -> None:
    # device_for is read afresh at each open, so a selection change followed by
    # retap moves the tap to the newly chosen device.
    h = _MeterHarness(device=1)
    h.meter.start()
    assert h.opens == [1]

    h.device = 9
    h.meter.retap()
    assert h.inners[0].stopped is True  # old device released first
    assert h.opens == [1, 9]


def test_input_meter_open_failure_leaves_it_flat_and_retries() -> None:
    # open_fn returns None on a device that will not open: the meter stays flat
    # with no stream, and a later resume tries again.
    opens: list[int | None] = []

    def open_fn(device: int | None, _on_level: Any, _on_lost: Any = None) -> None:
        opens.append(device)

    meter = InputMeter(
        on_level=lambda _v: None, device_for=lambda: None, open_fn=open_fn
    )
    meter.start()
    assert opens == [None]
    # No stream to close, so pause/resume just retry the open.
    meter.pause()
    meter.resume()
    assert opens == [None, None]


def test_input_meter_skips_open_when_no_input_available() -> None:
    # available_fn gates the whole open: a no-microphone host never reaches
    # open_fn, so the alarming PortAudio-open ALSA stderr is never emitted.
    opens: list[int | None] = []

    def open_fn(device: int | None, _on_level: Any, _on_lost: Any = None) -> None:
        opens.append(device)

    meter = InputMeter(
        on_level=lambda _v: None,
        device_for=lambda: 3,
        open_fn=open_fn,
        available_fn=lambda: False,
    )
    meter.start()
    meter.resume()
    meter.retap()
    assert opens == []


def test_input_meter_rearms_when_input_becomes_available() -> None:
    # A mic plugged in after launch: a rescan flips availability True and
    # re-taps (pause+resume), so the meter opens on the newly present device.
    available = {"ok": False}
    opens: list[int | None] = []

    def open_fn(
        device: int | None, _on_level: Any, _on_lost: Any = None
    ) -> MeterStream:
        opens.append(device)
        return MeterStream(_FakeInner())

    meter = InputMeter(
        on_level=lambda _v: None,
        device_for=lambda: 3,
        open_fn=open_fn,
        available_fn=lambda: available["ok"],
    )
    meter.start()
    assert opens == []  # no input yet, so nothing opened

    available["ok"] = True
    meter.pause()
    meter.resume()
    assert opens == [3]


def test_input_meter_handle_device_lost_closes_the_stream() -> None:
    # The device vanished mid-capture: the marshalled loss handler stops and
    # releases the dead stream without raising.
    h = _MeterHarness(device=1)
    h.meter.start()
    assert len(h.inners) == 1

    h.meter.handle_device_lost()
    assert h.inners[0].stopped is True
