"""TakePlayer tests: real WAV read, faked output stream, no hardware required.

The take WAV is written with libsndfile and read back by the real controller.
Only the ``sd.OutputStream`` factory is faked (injected as ``open_fn``, the same
seam ``wiring.InputMeter`` uses for its stream), so the frame-cursor math and the
play/pause/resume/finish transitions are exercised without opening a device this
sandbox does not have. The fake stream is pumped block by block, standing in for
what PortAudio's callback thread would do on a real device.
"""

from pathlib import Path
from typing import Any

import numpy as np
import pytest
import sounddevice as sd
import soundfile as sf
from voxtype_tuner.player import PlayerError, TakePlayer


def _write_take(path: str, frames: int = 100, samplerate: int = 16000) -> None:
    """Write a mono PCM16 take of exactly ``frames`` samples."""
    t = np.linspace(0.0, 8 * np.pi, frames, endpoint=False)
    samples = (0.2 * np.sin(t) * 32767).astype(np.int16)
    sf.write(path, samples, samplerate, subtype="PCM_16")


class _FakeStream:
    """A driveable stand-in for ``sd.OutputStream``.

    A real device would call the player's callback on its own thread; here the
    test pumps it in fixed blocks to advance the cursor. ``stop`` fires
    ``finished_callback`` exactly as PortAudio does whenever a stream goes
    inactive (a pause-stop as well as a natural end), so the player's guard that
    a pause is silent is under test too.
    """

    def __init__(
        self,
        samplerate: int,
        channels: int,
        callback: Any,
        finished_callback: Any,
    ) -> None:
        self.samplerate = samplerate
        self.channels = channels
        self.callback = callback
        self.finished_callback = finished_callback
        self.starts = 0
        self.stops = 0
        self.closes = 0
        # Set to simulate the output device vanishing mid-session, so start()
        # and stop() raise the way a real PortAudio call would on a dead device.
        self.raise_on_start = False
        self.raise_on_stop = False

    def start(self) -> None:
        self.starts += 1
        if self.raise_on_start:
            msg = "device start failed"
            raise sd.PortAudioError(msg)

    def stop(self) -> None:
        self.stops += 1
        if self.raise_on_stop:
            msg = "device stop failed"
            raise sd.PortAudioError(msg)
        self.finished_callback()

    def close(self) -> None:
        self.closes += 1

    def pump(self, frames: int) -> bool:
        """Drive one callback block; return True once the take has finished."""
        outdata = np.zeros((frames, self.channels), dtype="float32")
        try:
            self.callback(outdata, frames, None, None)
        except sd.CallbackStop:
            self.finished_callback()
            return True
        return False


def _make_player(
    on_finished: Any = None,
) -> tuple[TakePlayer, dict[str, _FakeStream]]:
    created: dict[str, _FakeStream] = {}

    def open_fn(
        samplerate: int, channels: int, callback: Any, finished_callback: Any
    ) -> _FakeStream:
        stream = _FakeStream(samplerate, channels, callback, finished_callback)
        created["stream"] = stream
        return stream

    return TakePlayer(open_fn=open_fn, on_finished=on_finished), created


def test_progress_is_monotonic_then_resets_on_finish(tmp_path: Path) -> None:
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    finished = {"count": 0}
    player, created = _make_player(
        on_finished=lambda: finished.__setitem__("count", finished["count"] + 1)
    )

    assert player.progress() == 0.0
    assert not player.is_playing()

    player.toggle(wav)  # idle -> start
    assert player.is_playing()
    stream = created["stream"]
    assert stream.starts == 1

    seen = []
    for _ in range(4):  # 4 * 20 = 80 of 100 frames
        assert not stream.pump(20)
        seen.append(player.progress())
    assert seen == sorted(seen)  # monotonic, no regressions
    assert seen[0] < seen[-1]
    assert seen[-1] == pytest.approx(0.8)

    assert stream.pump(20)  # the 100th frame ends the take
    assert finished["count"] == 1  # natural end signals exactly once
    assert not player.is_playing()
    assert player.progress() == 0.0  # rewound on finish


def test_pause_freezes_cursor_and_resume_continues(tmp_path: Path) -> None:
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    finished = {"count": 0}
    player, created = _make_player(
        on_finished=lambda: finished.__setitem__("count", finished["count"] + 1)
    )

    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(30)
    assert player.progress() == pytest.approx(0.3)

    player.toggle(wav)  # pause
    assert not player.is_playing()
    assert stream.stops == 1
    # A pause halts the device but must not signal completion or lose the place.
    assert finished["count"] == 0
    assert player.progress() == pytest.approx(0.3)

    player.toggle(wav)  # resume
    assert player.is_playing()
    assert stream.starts == 2  # same stream restarted, not reopened
    stream.pump(30)
    assert player.progress() == pytest.approx(0.6)  # continued from the freeze


def test_seek_while_playing_moves_cursor_without_teardown(tmp_path: Path) -> None:
    # Seeking a playing take is a pure cursor move: it must keep playing (no
    # pause, no stream reopen) and the callback must continue writing from the
    # new position, so the fill boundary jumps and playback carries on from it.
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()

    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(20)
    assert player.progress() == pytest.approx(0.2)

    player.seek(0.75)
    assert player.is_playing()  # still playing
    assert stream.stops == 0  # the stream was not torn down
    assert stream.starts == 1  # nor reopened
    assert player.progress() == pytest.approx(0.75)

    stream.pump(10)  # the callback continues from the sought frame
    assert player.progress() == pytest.approx(0.85)


def test_seek_while_paused_keeps_paused_and_resume_from_sought(
    tmp_path: Path,
) -> None:
    # Seeking a paused take moves the frozen cursor but must not restart audio.
    # The later resume then begins from the sought frame, not the old one.
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()

    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(20)
    player.toggle(wav)  # pause
    assert not player.is_playing()
    assert player.progress() == pytest.approx(0.2)

    player.seek(0.5)
    assert not player.is_playing()  # seeking does not resume playback
    assert stream.starts == 1  # no restart on the seek itself
    assert player.progress() == pytest.approx(0.5)

    player.toggle(wav)  # resume
    assert player.is_playing()
    assert stream.starts == 2  # same stream restarted
    stream.pump(10)  # continues from the sought frame, not 0.2
    assert player.progress() == pytest.approx(0.6)


def test_seek_while_idle_arms_next_play_from_sought(tmp_path: Path) -> None:
    # A take played to its natural end sits idle with the buffer still loaded.
    # Seeking repositions the clock now AND arms the next Play: pressing Play
    # must begin FROM the sought frame, not rewind to 0 (idle Play routes
    # through start(), which reloads and would otherwise discard the scrub).
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()

    player.toggle(wav)  # start
    assert created["stream"].pump(100)  # play to the natural end -> idle, rewound
    assert not player.is_playing()
    assert player.progress() == 0.0

    assert player.seek(0.4)  # idle-with-buffer: moves the clock and arms Play
    assert not player.is_playing()  # seeking an idle take does not start it
    assert player.progress() == pytest.approx(0.4)

    player.toggle(wav)  # Play again -> must honor the armed 0.4, not restart at 0
    assert player.is_playing()
    resumed = created["stream"]  # start() opened a fresh stream
    assert player.progress() == pytest.approx(0.4)  # begins FROM the sought frame
    resumed.pump(10)
    assert player.progress() == pytest.approx(0.5)  # and climbs from there


def test_seek_clamps_to_unit_interval(tmp_path: Path) -> None:
    # Out-of-range fractions (a drag past either end of the strip) clamp, so the
    # cursor can never land before the take or past its final frame.
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()

    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(30)

    player.seek(-0.5)
    assert player.progress() == 0.0  # clamped to the start
    player.seek(1.5)
    assert player.progress() == pytest.approx(1.0)  # clamped to the end


def test_seek_before_first_play_arms_play_from_sought(tmp_path: Path) -> None:
    # A freshly recorded take that has never been played has no buffer loaded
    # yet (total 0), so the seek moves no live cursor and cannot divide by zero.
    # It still arms the position, so the FIRST Play loads the take and begins
    # from the sought frame rather than the top.
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()

    assert player.seek(0.4)  # armed even with nothing loaded (total 0)
    assert player.progress() == 0.0  # no buffer yet, so still 0
    assert not player.is_playing()

    player.toggle(wav)  # first Play loads the take and applies the arm
    assert player.is_playing()
    stream = created["stream"]
    assert player.progress() == pytest.approx(0.4)  # begins FROM the sought frame
    stream.pump(10)
    assert player.progress() == pytest.approx(0.5)


def test_seek_in_the_final_block_still_finishes(tmp_path: Path) -> None:
    # A seek can land in the window between the callback writing the final
    # cursor (>= total, raising CallbackStop) and finished_callback firing. The
    # end-of-take must still be recognized (player idle, on_finished signaled),
    # not masked into a stuck "playing" by the smaller cursor the seek left.
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    finished = {"count": 0}
    player, created = _make_player(
        on_finished=lambda: finished.__setitem__("count", finished["count"] + 1)
    )

    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(80)

    # Drive the final block by hand so a seek can slip into the race window: the
    # callback exhausts the take (cursor -> 100, latches the natural end) and
    # raises CallbackStop, THEN a seek drags the cursor back before the stream's
    # finished_callback runs.
    outdata = np.zeros((20, stream.channels), dtype="float32")
    with pytest.raises(sd.CallbackStop):
        stream.callback(outdata, 20, None, None)
    player.seek(0.5)  # lands mid-race, moving the cursor below total
    stream.finished_callback()  # PortAudio fires this after CallbackStop

    assert not player.is_playing()  # ended, not stuck reporting "playing"
    assert finished["count"] == 1  # the natural end still signals exactly once
    assert player.progress() == 0.0  # rewound on finish
    assert not player.is_playing()


def test_stop_rewinds_and_closes_the_stream(tmp_path: Path) -> None:
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    finished = {"count": 0}
    player, created = _make_player(
        on_finished=lambda: finished.__setitem__("count", finished["count"] + 1)
    )

    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(50)
    assert player.progress() == pytest.approx(0.5)

    player.stop()
    assert not player.is_playing()
    assert player.progress() == 0.0
    assert stream.stops == 1
    assert stream.closes == 1
    # A stop is not a natural end, so on_finished must stay quiet.
    assert finished["count"] == 0


def test_toggle_missing_wav_raises_player_error(tmp_path: Path) -> None:
    # Playing before anything was recorded (bare checkout, no seeded sample)
    # must surface as a PlayerError, not a LibsndfileError escaping the thread.
    player, _ = _make_player()
    with pytest.raises(PlayerError) as excinfo:
        player.toggle(str(tmp_path / "absent.wav"))
    assert "cannot read recording" in str(excinfo.value)
    assert not player.is_playing()


def test_toggle_corrupt_wav_raises_player_error(tmp_path: Path) -> None:
    bad = tmp_path / "not-a-wav.wav"
    bad.write_bytes(b"this is not RIFF data")
    player, _ = _make_player()
    with pytest.raises(PlayerError) as excinfo:
        player.toggle(str(bad))
    assert "cannot read recording" in str(excinfo.value)
    assert not player.is_playing()


def test_pause_device_loss_resets_and_raises(tmp_path: Path) -> None:
    # The output device vanishing under a paused stream must surface as a
    # PlayerError and reset the controller to idle, so is_playing() cannot stay
    # stuck true and desync the Play/Pause button from the real state.
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()
    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(30)

    stream.raise_on_stop = True
    with pytest.raises(PlayerError):
        player.toggle(wav)  # pause on a device that just disappeared
    assert not player.is_playing()
    assert player.progress() == 0.0


def test_resume_device_loss_resets_and_raises(tmp_path: Path) -> None:
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)
    player, created = _make_player()
    player.toggle(wav)  # start
    stream = created["stream"]
    stream.pump(30)
    player.toggle(wav)  # pause cleanly
    assert not player.is_playing()

    stream.raise_on_start = True
    with pytest.raises(PlayerError):
        player.toggle(wav)  # resume on a device that just disappeared
    assert not player.is_playing()
    assert player.progress() == 0.0


def test_start_no_output_device_raises_player_error(tmp_path: Path) -> None:
    wav = str(tmp_path / "take.wav")
    _write_take(wav, frames=100)

    def _boom(*_args: Any, **_kwargs: Any) -> Any:
        msg = "no default output device"
        raise sd.PortAudioError(msg)

    player = TakePlayer(open_fn=_boom)
    with pytest.raises(PlayerError) as excinfo:
        player.toggle(wav)
    assert str(excinfo.value)  # UI-displayable, non-empty message
    assert not player.is_playing()
