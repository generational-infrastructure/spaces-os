"""Tests for the scratch-daemon streaming session.

A bash fake stands in for voxtype and implements the surface the session
drives: ``daemon`` (writes the pid lockfile and the state file under
``$XDG_RUNTIME_DIR/voxtype``, flips state on SIGUSR1/SIGUSR2 exactly like the
real signal-driven CLI), ``record start/stop`` (signals the lockfile pid) and
``status --follow --format json`` (one JSON line per state transition, a
synthesized ``stopped`` when the daemon dies). Env knobs script the timing so
readiness, self-stop-at-cap, mid-session death and wedged startup are all
deterministic. No audio, no models.
"""

from __future__ import annotations

import os
import threading
import time
import tomllib
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest
from voxtype_tuner import params, streaming
from voxtype_tuner.params import TranscribeParams
from voxtype_tuner.streaming import StreamOutcome, StreamSession, daemon_config_toml

FAKE_VOXTYPE = """\
cfg=""
if [ "${1:-}" = "-c" ]; then cfg="$2"; shift 2; fi
cmd="${1:-}"; shift || true
rd="${XDG_RUNTIME_DIR:-/tmp}/voxtype"
state="$rd/state"
case "$cmd" in
  daemon)
    if [ -n "${CONFIG_DUMP:-}" ]; then cp "$cfg" "$CONFIG_DUMP"; fi
    mkdir -p "$rd"
    echo $$ > "$rd/voxtype.lock"
    if [ -n "${FAKE_PID_FILE:-}" ]; then echo $$ > "$FAKE_PID_FILE"; fi
    sleep "${FAKE_READY_DELAY:-0.05}"
    echo idle > "$state"
    on_start() {
      echo streaming > "$state"
      if [ -n "${FAKE_SELF_STOP_AFTER:-}" ]; then
        ( sleep "$FAKE_SELF_STOP_AFTER"; echo idle > "$state" ) &
      fi
      if [ -n "${FAKE_DIE_AFTER:-}" ]; then
        ( sleep "$FAKE_DIE_AFTER"; kill -9 $$ ) &
      fi
    }
    on_stop() { ( sleep "${FAKE_FINALIZE_DELAY:-0.05}"; echo idle > "$state" ) & }
    trap on_start USR1
    trap on_stop USR2
    trap 'rm -f "$rd/voxtype.lock"; exit 0' TERM
    while :; do sleep 0.05; done
    ;;
  record)
    action="${1:-}"
    pid="$(cat "$rd/voxtype.lock" 2>/dev/null)" || {
      echo "Error: Voxtype daemon is not running." >&2
      exit 1
    }
    case "$action" in
      start) kill -USR1 "$pid" ;;
      stop) kill -USR2 "$pid" ;;
    esac
    ;;
  status)
    last=""
    while :; do
      pid="$(cat "$rd/voxtype.lock" 2>/dev/null || true)"
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        printf '{"text": "", "alt": "stopped", "class": "stopped", "tooltip": ""}\\n'
        exit 0
      fi
      cur="$(cat "$state" 2>/dev/null || true)"
      if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
        printf '{"text": "", "alt": "%s", "class": "%s", "tooltip": ""}\\n' "$cur" "$cur"
        last="$cur"
      fi
      sleep 0.03
    done
    ;;
esac
"""


def _write_fake(tmp_path: Path) -> str:
    script = tmp_path / "voxtype"
    script.write_text("#!/usr/bin/env bash\n" + FAKE_VOXTYPE)
    script.chmod(0o755)
    return str(script)


def _params(max_duration: int = 60) -> TranscribeParams:
    return TranscribeParams(
        engine="parakeet",
        model="parakeet-unified-en-0.6b",
        language="auto",
        initial_prompt="",
        vad=True,
        vad_threshold=0.4,
        max_duration=max_duration,
    )


def _nemotron_params(max_duration: int = 60) -> TranscribeParams:
    # Nemotron has no tuner model selection, so its model is empty. The daemon
    # config's model comes from the provisioned path (or the default name).
    return TranscribeParams(
        engine="nemotron",
        model="",
        language="auto",
        initial_prompt="",
        vad=True,
        vad_threshold=0.4,
        max_duration=max_duration,
    )


class Events:
    """Capture the session callbacks for assertions."""

    def __init__(self) -> None:
        self.live = threading.Event()
        self.done = threading.Event()
        self.ticks: list[float] = []
        self.outcome: StreamOutcome | None = None

    def on_live(self) -> None:
        self.live.set()

    def on_tick(self, elapsed_s: float) -> None:
        self.ticks.append(elapsed_s)

    def on_done(self, outcome: StreamOutcome) -> None:
        self.outcome = outcome
        self.done.set()


def _session(
    fake: str, events: Events, p: TranscribeParams | None = None, **kwargs: Any
) -> StreamSession:
    return StreamSession(
        p or _params(),
        voxtype_bin=fake,
        on_live=events.on_live,
        on_tick=events.on_tick,
        on_done=events.on_done,
        tick_interval_s=0.05,
        **kwargs,
    )


def _pid_gone(pid: int, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


def test_daemon_config_pins_profile_and_disables_hotkey() -> None:
    # The scratch config must carry everything a headless streaming daemon
    # needs: the streaming flag with the blessed 56/560/56 context profile
    # (pinned, no tuner knob for it), the hotkey OFF (record start/stop is
    # the only driver), and the tuner's VAD / max-duration params. Output is
    # deliberately NOT configured: upstream's default typing IS the feature.
    cfg = tomllib.loads(daemon_config_toml(_params(max_duration=30)))

    assert cfg["engine"] == "parakeet"
    assert cfg["parakeet"]["model"] == "parakeet-unified-en-0.6b"
    assert cfg["parakeet"]["streaming"] is True
    assert cfg["parakeet"]["streaming_chunk_secs"] == 0.56
    assert cfg["parakeet"]["streaming_left_context_secs"] == 5.6
    assert cfg["parakeet"]["streaming_right_context_secs"] == 0.56
    assert cfg["hotkey"]["enabled"] is False
    assert cfg["vad"]["enabled"] is True
    assert cfg["vad"]["threshold"] == 0.4
    assert cfg["audio"]["max_duration_secs"] == 30
    assert "output" not in cfg


def test_daemon_config_carries_the_selected_device() -> None:
    # A live session must capture from the same mic the tuner's Record uses, so
    # the chosen [audio] device string reaches the scratch daemon's config.
    cfg = tomllib.loads(daemon_config_toml(replace(_params(), device="Blue Yeti")))
    assert cfg["audio"]["device"] == "Blue Yeti"


def test_daemon_config_defaults_device_when_unset() -> None:
    cfg = tomllib.loads(daemon_config_toml(_params()))
    assert cfg["audio"]["device"] == "default"


def test_daemon_config_uses_absolute_path_for_system_models() -> None:
    cfg = tomllib.loads(
        daemon_config_toml(_params(), model_path="/nix/store/abc-parakeet-unified")
    )
    assert cfg["parakeet"]["model"] == "/nix/store/abc-parakeet-unified"
    assert cfg["parakeet"]["streaming"] is True


def test_daemon_config_refuses_non_streaming_selection() -> None:
    p = TranscribeParams(
        engine="parakeet",
        model="parakeet-tdt-0.6b-v3",
        language="auto",
        initial_prompt="",
        vad=False,
        vad_threshold=0.5,
        max_duration=60,
    )
    with pytest.raises(ValueError, match="streaming"):
        daemon_config_toml(p)


def test_daemon_config_nemotron_is_just_the_streaming_boolean() -> None:
    # Nemotron ≠ parakeet: its streaming config carries ONLY streaming = true.
    # Emitting parakeet's mel-frame context profile here would make voxtype
    # reject the config, so the branch must never leak any context-secs key or
    # a [parakeet] table. The engine-agnostic daemon tail (hotkey/vad/audio) is
    # identical to parakeet's.
    cfg = tomllib.loads(
        daemon_config_toml(
            _nemotron_params(max_duration=30),
            model_path="/nix/store/abc-nemotron-3.5-asr-streaming-0.6b",
        )
    )

    assert cfg["engine"] == "nemotron"
    assert cfg["nemotron"]["model"] == "/nix/store/abc-nemotron-3.5-asr-streaming-0.6b"
    assert cfg["nemotron"]["streaming"] is True
    assert cfg["nemotron"]["target_lang"] == "auto"
    assert "parakeet" not in cfg
    for key in (
        "streaming_chunk_secs",
        "streaming_left_context_secs",
        "streaming_right_context_secs",
    ):
        assert key not in cfg["nemotron"]
    assert cfg["hotkey"]["enabled"] is False
    assert cfg["vad"]["enabled"] is True
    assert cfg["vad"]["threshold"] == 0.4
    assert cfg["audio"]["max_duration_secs"] == 30
    assert "output" not in cfg


def test_daemon_config_nemotron_falls_back_to_default_model_name() -> None:
    # A bare checkout hands in no provisioned path. Emit the resolvable default
    # registry name rather than a nonsense empty model.
    cfg = tomllib.loads(daemon_config_toml(_nemotron_params()))
    assert cfg["nemotron"]["model"] == params.DEFAULT_NEMOTRON_MODEL
    assert cfg["nemotron"]["streaming"] is True


def test_daemon_config_nemotron_maps_language_to_target_lang() -> None:
    # A live nemotron session honors the picker's language just like the batch
    # path: the single-select code maps to its nemotron target_lang locale.
    p = replace(_nemotron_params(), language="fr")
    cfg = tomllib.loads(daemon_config_toml(p, model_path="/models/nem"))
    assert cfg["nemotron"]["target_lang"] == "fr-FR"
    assert cfg["nemotron"]["streaming"] is True


def test_nemotron_session_drives_streaming_end_to_end(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The wiring proof for the live pill on nemotron: the session must generate
    # an engine="nemotron", [nemotron].streaming=true config, reach the
    # streaming state (on_live + at least one tick, that IS "a partial" at the
    # tuner's observation grain), stop, finalize and reap cleanly. The fake
    # voxtype scripts the daemon. No model and no audio are involved.
    pid_file = tmp_path / "daemon.pid"
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("FAKE_PID_FILE", str(pid_file))
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    monkeypatch.setenv("FAKE_FINALIZE_DELAY", "0.1")
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(
        fake,
        events,
        p=_nemotron_params(),
        model_path="/nix/store/abc-nemotron-3.5-asr-streaming-0.6b",
    )

    session.start()
    assert events.live.wait(10.0), "nemotron session never went live"
    time.sleep(0.3)  # the "speech"
    session.stop()
    assert events.done.wait(10.0), "session never completed"

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is True
    assert outcome.error is None
    assert outcome.finalize_s is not None
    assert len(events.ticks) >= 1  # at least one partial observed

    # The generated config really was the nemotron streaming shape, with none
    # of parakeet's context profile.
    cfg = tomllib.loads(dump.read_text())
    assert cfg["engine"] == "nemotron"
    assert cfg["nemotron"]["streaming"] is True
    assert cfg["nemotron"]["model"] == "/nix/store/abc-nemotron-3.5-asr-streaming-0.6b"
    assert "parakeet" not in cfg
    assert "streaming_chunk_secs" not in cfg["nemotron"]

    # Everything is reaped: process dead, scratch dir gone.
    assert _pid_gone(int(pid_file.read_text()))
    runtime_dir = session.runtime_dir
    assert runtime_dir is not None
    assert not Path(runtime_dir).exists()


def test_happy_path_reports_session_metrics_and_reaps(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pid_file = tmp_path / "daemon.pid"
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("FAKE_PID_FILE", str(pid_file))
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    monkeypatch.setenv("FAKE_FINALIZE_DELAY", "0.1")
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events)

    session.start()
    assert events.live.wait(10.0), "session never went live"
    time.sleep(0.3)  # the "speech"
    session.stop()
    session.stop()  # a double-press must not stack a second stop
    assert events.done.wait(10.0), "session never completed"

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is True
    assert outcome.error is None
    assert outcome.session_s >= 0.25
    assert outcome.finalize_s is not None
    assert outcome.finalize_s >= 0.05
    assert outcome.hit_max_duration is False
    assert len(events.ticks) >= 2  # the live caption had material to tick with

    # The daemon was driven through the isolated runtime dir (the fake read
    # $XDG_RUNTIME_DIR for its lockfile/state, and got the -c config)...
    cfg = tomllib.loads(dump.read_text())
    assert cfg["parakeet"]["streaming"] is True
    # ...and everything is reaped: process dead, scratch dir gone.
    assert _pid_gone(int(pid_file.read_text()))
    runtime_dir = session.runtime_dir
    assert runtime_dir is not None
    assert not Path(runtime_dir).exists()


def test_session_the_daemon_ends_at_the_cap_reads_max_duration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # No stop request: the daemon cuts the session itself at max_duration
    # (here: cap 1s, fake self-stops at ~1s). The outcome must carry the
    # distinct hit_max_duration marker, not a fabricated finalize wait.
    monkeypatch.setenv("FAKE_SELF_STOP_AFTER", "1.0")
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events, p=_params(max_duration=1))

    session.start()
    assert events.live.wait(10.0)
    assert events.done.wait(10.0)

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is True
    assert outcome.hit_max_duration is True
    assert outcome.finalize_s is None
    assert outcome.session_s >= 0.9


def test_daemon_ending_early_is_not_flagged_as_max_duration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("FAKE_SELF_STOP_AFTER", "0.2")
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events, p=_params(max_duration=60))

    session.start()
    assert events.done.wait(10.0)

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is True
    assert outcome.hit_max_duration is False
    assert outcome.finalize_s is None


def test_daemon_death_mid_session_fails_distinctly(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("FAKE_DIE_AFTER", "0.2")
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events)

    session.start()
    assert events.live.wait(10.0)
    assert events.done.wait(10.0), "daemon death must resolve the session, not hang"

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is False
    assert outcome.error is not None
    assert "daemon" in outcome.error
    runtime_dir = session.runtime_dir
    assert runtime_dir is not None
    assert not Path(runtime_dir).exists()


def test_daemon_never_ready_times_out_and_reaps(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pid_file = tmp_path / "daemon.pid"
    monkeypatch.setenv("FAKE_PID_FILE", str(pid_file))
    monkeypatch.setenv("FAKE_READY_DELAY", "30")
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events, ready_timeout_s=0.4)

    session.start()
    assert events.done.wait(10.0)

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is False
    assert outcome.error is not None
    assert "ready" in outcome.error
    assert _pid_gone(int(pid_file.read_text()))


def test_missing_binary_fails_without_leaking_the_scratch_dir(
    tmp_path: Path,
) -> None:
    events = Events()
    session = _session(str(tmp_path / "does-not-exist"), events)

    session.start()
    assert events.done.wait(10.0)

    outcome = events.outcome
    assert outcome is not None
    assert outcome.ok is False
    assert outcome.error is not None
    runtime_dir = session.runtime_dir
    assert runtime_dir is not None
    assert not Path(runtime_dir).exists()


def test_reap_kills_everything_and_silences_callbacks(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Reap is the mode-switch/app-exit path: the daemon and its scratch dir
    # must go away, and no late callback may repaint the UI afterwards.
    pid_file = tmp_path / "daemon.pid"
    monkeypatch.setenv("FAKE_PID_FILE", str(pid_file))
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events)

    session.start()
    assert events.live.wait(10.0)
    session.reap()

    assert _pid_gone(int(pid_file.read_text()))
    runtime_dir = session.runtime_dir
    assert runtime_dir is not None
    assert not Path(runtime_dir).exists()
    assert not events.done.wait(0.5), "reap must silence on_done"


def test_reap_active_covers_registered_sessions(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The lifecycle hook (Ctrl-C/Ctrl-D → quit → _run's finally) calls
    # reap_active() without holding a session reference. The registry must
    # route it to whatever is live.
    pid_file = tmp_path / "daemon.pid"
    monkeypatch.setenv("FAKE_PID_FILE", str(pid_file))
    fake = _write_fake(tmp_path)
    events = Events()
    session = _session(fake, events)

    session.start()
    assert events.live.wait(10.0)
    streaming.reap_active()

    assert _pid_gone(int(pid_file.read_text()))
    runtime_dir = session.runtime_dir
    assert runtime_dir is not None
    assert not Path(runtime_dir).exists()
    assert not events.done.wait(0.5)
