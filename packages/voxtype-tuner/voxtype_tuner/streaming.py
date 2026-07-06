"""Scratch-daemon streaming sessions: spawn, drive, observe, reap.

voxtype's streaming pipeline types its live transcript into the focused
window. That is the product behavior, and the tuner exposes it rather than
capturing it (the transcript field is focused so it receives the typing as
any window would). What this module owns is everything around that:

- a COMPLETE-enough scratch config (voxtype deep-merges a ``-c`` file over
  its built-in defaults) with the streaming profile pinned and the hotkey
  disabled, in an isolated ``XDG_RUNTIME_DIR`` tmpdir so the scratch daemon's
  lockfile/state/signals can never collide with the user's real daemon.
- the drive sequence: wait for readiness (the daemon writes ``idle`` once its
  run loop (model load included) is up), ``record start``, ``record stop``.
- the observation loop: ``status --follow --format json`` emits one line per
  state transition (``idle``/``streaming``/``transcribing`` plus a
  synthesized ``stopped`` when the daemon dies), and those transitions carry
  the only honest wall-clocks streaming has: session length and the
  stop→idle finalize wait.
- single-flight bookkeeping and reaping: every started session registers
  itself so :func:`reap_active` (hooked behind the terminal-lifecycle quit
  paths) can kill the daemon and remove the tmpdir even when the UI never
  gets to.

Callbacks (``on_live``/``on_tick``/``on_done``) fire on session-owned worker
threads. The caller marshals onto the UI thread, mirroring the download and
transcribe wiring. Like those modules, nothing here raises across the API:
failures arrive as an ``ok=False`` :class:`StreamOutcome`.
"""

from __future__ import annotations

import contextlib
import json
import os
import queue
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from voxtype_tuner import params

if TYPE_CHECKING:
    from collections.abc import Callable
    from typing import IO

    from voxtype_tuner.params import TranscribeParams

# A daemon-ended session (no stop request) counts as "reached max duration"
# when it lasted at least this fraction of the configured cap. Observation is
# IPC-grained, so an exact comparison would randomly miss real cap hits.
_MAX_DURATION_ATTRIBUTION = 0.9

# How long after record-start the daemon gets to reach the "streaming" state
# before the session is declared failed (capture/backend spin-up, not model
# load, since readiness already covered that).
_STREAM_START_TIMEOUT_S = 15.0

# Slack past the configured max duration before the observation loop declares
# the session wedged, generous because the daemon enforces the cap itself.
_SESSION_SLACK_S = 60.0

# Sentinel state the follow reader enqueues at EOF so the observation loop
# can tell "stream closed" from "no transition yet".
_EOF = "__eof__"


def daemon_config_toml(p: TranscribeParams, model_path: str | None = None) -> str:
    """Render the scratch daemon's config for a streaming session.

    Builds on the selected engine's minimal config renderer and adds what
    headless daemon operation needs: hotkey OFF (``record start/stop`` is the
    only driver), the tuner's VAD settings, the chosen recording ``[audio]
    device`` (so a session captures from the same mic Record would), and the
    max-duration cap the daemon enforces itself. Output is deliberately left at
    voxtype's default (typing). The typed live transcript IS the streaming
    experience.

    The two engines do NOT share a streaming config shape. Parakeet's renderer
    pins the blessed 56/560/56 mel-frame context profile the capable model
    refuses to load without, while nemotron's is JUST ``streaming = true`` (plus its
    provisioned model and ``target_lang``), and MUST NOT carry any of parakeet's
    context keys. Branching here is the whole difference. Everything after is
    engine-agnostic daemon plumbing.

    Raises ValueError for a selection that cannot stream. The UI gate keeps
    that unreachable, so tripping it is a wiring bug, not a user error.
    """
    if not params.engine_can_stream(p.engine, p.model):
        msg = f"not streaming-capable: {p.engine} · {p.model or '(no model)'}"
        raise ValueError(msg)
    if p.engine == "nemotron":
        # Nemotron has no tuner model selection. Its model is the provisioned
        # store dir handed in (else the resolvable default name). Streaming is
        # the lone streaming key, no context-secs. The picker's language
        # selection maps to nemotron's single-target target_lang (Auto → "auto")
        # so a live session honors the chosen locale like the batch path does.
        engine_config = params.nemotron_config_toml(
            model_path or params.DEFAULT_NEMOTRON_MODEL,
            target_lang=params.nemotron_target_lang(p.language),
            streaming=True,
        )
    else:
        engine_config = params.parakeet_config_toml(p.model, path=model_path)
    lines = [
        engine_config,
        "[hotkey]",
        "enabled = false",
        "",
        "[vad]",
        f"enabled = {'true' if p.vad else 'false'}",
        f"threshold = {p.vad_threshold:.2f}",
        "",
        "[audio]",
        f"max_duration_secs = {p.max_duration}",
        # The chosen recording input, so a live session captures from the same
        # mic the tuner's Record would. Empty normalizes to "default", the
        # system default, which always resolves.
        f'device = "{p.device or "default"}"',
    ]
    return "\n".join(lines) + "\n"


@dataclass(frozen=True)
class StreamOutcome:
    """How a streaming session ended, with its honest wall-clocks.

    ``session_s`` is the streaming span (live → stop request, or → idle when
    the daemon ended the session itself). ``finalize_s`` is the stop→idle
    wait, ``None`` without a stop request, since nothing was measured.
    ``hit_max_duration`` marks a daemon-ended session that ran the configured
    cap out. ``error`` is a short UI-ready reason when ``ok`` is False.
    """

    ok: bool
    error: str | None
    session_s: float
    finalize_s: float | None
    hit_max_duration: bool


def _failure(error: str) -> StreamOutcome:
    return StreamOutcome(
        ok=False, error=error, session_s=0.0, finalize_s=None, hit_max_duration=False
    )


_ACTIVE: set[StreamSession] = set()
_ACTIVE_LOCK = threading.Lock()


def reap_active() -> None:
    """Reap every live session (the app-exit / terminal-lifecycle hook).

    Called after the Slint event loop returns (including the Ctrl-C/SIGTERM
    and Ctrl-D quit paths), so a scratch daemon can never outlive the tuner.
    """
    with _ACTIVE_LOCK:
        sessions = list(_ACTIVE)
    for session in sessions:
        session.reap()


class StreamSession:
    """One scratch-daemon streaming session, worker-thread driven.

    ``start()`` spawns the daemon and returns immediately. ``on_live`` fires
    when the daemon reports the ``streaming`` state, ``on_tick`` carries the
    elapsed session time for the live caption, and ``on_done`` delivers the
    single terminal :class:`StreamOutcome`, exactly once, unless the session
    was reaped first (reaping silences callbacks, and the reaping caller owns the
    UI state it tears down).
    """

    def __init__(
        self,
        p: TranscribeParams,
        model_path: str | None = None,
        voxtype_bin: str = "voxtype",
        on_live: Callable[[], None] = lambda: None,
        on_tick: Callable[[float], None] = lambda _elapsed: None,
        on_done: Callable[[StreamOutcome], None] = lambda _outcome: None,
        ready_timeout_s: float = 120.0,
        tick_interval_s: float = 0.5,
        kill_grace_s: float = 3.0,
    ) -> None:
        self._p = p
        self._model_path = model_path
        self._bin = voxtype_bin
        self._on_live = on_live
        self._on_tick = on_tick
        self._on_done = on_done
        self._ready_timeout_s = ready_timeout_s
        self._tick_interval_s = tick_interval_s
        self._kill_grace_s = kill_grace_s

        self._lock = threading.Lock()
        self._daemon: subprocess.Popen[str] | None = None
        self._follow: subprocess.Popen[str] | None = None
        self._stop_requested_at: float | None = None
        self._silenced = False
        self._cleaned = False
        self._stderr_tail: deque[str] = deque(maxlen=20)

        # The isolated XDG_RUNTIME_DIR, public so callers/tests can assert
        # the scratch state is really gone after the session ends.
        self.runtime_dir: str | None = None

    def start(self) -> None:
        """Register the session and run it on a worker thread."""
        with _ACTIVE_LOCK:
            _ACTIVE.add(self)
        threading.Thread(target=self._run, daemon=True).start()

    def stop(self) -> None:
        """Request the stop→finalize path (idempotent, any thread)."""
        with self._lock:
            if self._stop_requested_at is not None or self._silenced:
                return
            self._stop_requested_at = time.monotonic()
        threading.Thread(target=self._send_record_stop, daemon=True).start()

    def reap(self) -> None:
        """Kill the daemon, drop the tmpdir, and silence all callbacks.

        The mode-switch / selection-change / app-exit path: the caller is
        tearing the session's UI state down itself, so a late ``on_done``
        repaint must never race it.
        """
        with self._lock:
            self._silenced = True
        self._cleanup()

    def _env(self) -> dict[str, str]:
        env = dict(os.environ)
        if self.runtime_dir is not None:
            env["XDG_RUNTIME_DIR"] = self.runtime_dir
        return env

    def _run(self) -> None:
        outcome = self._session_flow()
        self._cleanup()
        with self._lock:
            silenced = self._silenced
        if not silenced:
            self._on_done(outcome)

    def _session_flow(self) -> StreamOutcome:
        self.runtime_dir = tempfile.mkdtemp(prefix="voxtype-tuner-stream-")
        try:
            config = daemon_config_toml(self._p, self._model_path)
        except ValueError as exc:
            return _failure(str(exc))
        config_path = Path(self.runtime_dir) / "config.toml"
        config_path.write_text(config)

        argv = [self._bin, "-c", str(config_path), "daemon"]
        try:
            daemon = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self._env(),
                # Its own process group: reaping signals the group, so engine
                # helpers the daemon spawns die with it (the download-path
                # lesson about surviving grandchildren).
                start_new_session=True,
            )
        except OSError as exc:
            return _failure(str(exc))
        with self._lock:
            self._daemon = daemon
        self._drain(daemon)

        if not self._await_ready(daemon):
            if daemon.poll() is not None:
                return _failure(self._daemon_exit_reason(daemon))
            return _failure(
                f"voxtype daemon not ready after {self._ready_timeout_s:g}s"
            )

        transitions: queue.Queue[tuple[float, str]] = queue.Queue()
        try:
            follow = subprocess.Popen(
                [self._bin, "status", "--follow", "--format", "json"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                env=self._env(),
            )
        except OSError as exc:
            return _failure(f"voxtype status --follow failed: {exc}")
        with self._lock:
            self._follow = follow
        threading.Thread(
            target=self._read_follow, args=(follow, transitions), daemon=True
        ).start()

        error = self._record("start")
        if error is not None:
            return _failure(error)

        return self._observe(transitions, daemon)

    def _await_ready(self, daemon: subprocess.Popen[str]) -> bool:
        """Poll for the daemon's first state write (idle == run loop is up)."""
        assert self.runtime_dir is not None  # set by _session_flow  # noqa: S101
        state = Path(self.runtime_dir) / "voxtype" / "state"
        deadline = time.monotonic() + self._ready_timeout_s
        while time.monotonic() < deadline:
            if daemon.poll() is not None:
                return False
            if state.exists():
                return True
            time.sleep(0.025)
        return False

    def _observe(
        self,
        transitions: queue.Queue[tuple[float, str]],
        daemon: subprocess.Popen[str],
    ) -> StreamOutcome:
        live = self._await_state(
            transitions,
            {"streaming"},
            time.monotonic() + _STREAM_START_TIMEOUT_S,
            daemon,
        )
        if live is None:
            if daemon.poll() is not None:
                return _failure(self._daemon_exit_reason(daemon))
            return _failure("recording never started")
        live_at, _ = live
        self._on_live()

        ticker_stop = threading.Event()
        threading.Thread(
            target=self._tick, args=(live_at, ticker_stop), daemon=True
        ).start()
        try:
            deadline = live_at + self._p.max_duration + _SESSION_SLACK_S
            ended = self._await_state(
                transitions, {"idle", "stopped"}, deadline, daemon
            )
        finally:
            ticker_stop.set()

        if ended is None:
            return _failure("streaming session timed out")
        end_at, state = ended
        if state == "stopped":
            return _failure(self._daemon_exit_reason(daemon))

        with self._lock:
            stop_at = self._stop_requested_at
        if stop_at is not None:
            return StreamOutcome(
                ok=True,
                error=None,
                session_s=max(0.0, stop_at - live_at),
                finalize_s=max(0.0, end_at - stop_at),
                hit_max_duration=False,
            )
        session_s = end_at - live_at
        return StreamOutcome(
            ok=True,
            error=None,
            session_s=session_s,
            finalize_s=None,
            hit_max_duration=session_s
            >= _MAX_DURATION_ATTRIBUTION * self._p.max_duration,
        )

    def _await_state(
        self,
        transitions: queue.Queue[tuple[float, str]],
        wanted: set[str],
        deadline: float,
        daemon: subprocess.Popen[str],
    ) -> tuple[float, str] | None:
        """Next transition into one of ``wanted``, or None on deadline/EOF.

        Polls the daemon child between queue timeouts: a crashed scratch
        daemon is OUR zombie until ``poll()`` reaps it, so ``status
        --follow``'s signal-0 liveness probe would keep succeeding and never
        synthesize ``stopped``. The death has to be observed first-hand.
        """
        while True:
            if time.monotonic() >= deadline:
                return None
            try:
                at, state = transitions.get(timeout=0.1)
            except queue.Empty:
                if daemon.poll() is not None:
                    now = time.monotonic()
                    return (now, "stopped") if "stopped" in wanted else None
                continue
            if state == _EOF:
                return (at, "stopped") if "stopped" in wanted else None
            if state in wanted:
                return (at, state)

    def _tick(self, live_at: float, stop: threading.Event) -> None:
        while not stop.wait(self._tick_interval_s):
            with self._lock:
                if self._silenced or self._stop_requested_at is not None:
                    return
            self._on_tick(time.monotonic() - live_at)

    def _read_follow(
        self, follow: subprocess.Popen[str], transitions: queue.Queue[tuple[float, str]]
    ) -> None:
        assert follow.stdout is not None  # PIPE above  # noqa: S101
        for raw in follow.stdout:
            line = raw.strip()
            if not line:
                continue
            try:
                state = json.loads(line).get("alt", "")
            except ValueError:
                continue
            transitions.put((time.monotonic(), str(state)))
        transitions.put((time.monotonic(), _EOF))

    def _record(self, action: str) -> str | None:
        """Run ``voxtype record <action>``, returning a short error string on failure."""
        try:
            proc = subprocess.run(
                [self._bin, "record", action],
                capture_output=True,
                text=True,
                env=self._env(),
                timeout=10.0,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return f"voxtype record {action} failed: {exc}"
        if proc.returncode != 0:
            reason = proc.stderr.strip().splitlines()
            return f"voxtype record {action} failed: {reason[-1] if reason else proc.returncode}"
        return None

    def _send_record_stop(self) -> None:
        # Failure here means the daemon is already gone. The follow stream
        # reports that as "stopped" and the observe loop surfaces it.
        self._record("stop")

    def _drain(self, daemon: subprocess.Popen[str]) -> None:
        """Echo the daemon's output live (terminal debugging) and keep a tail."""

        def pump(stream: IO[str] | None, name: str, keep: bool) -> None:
            if stream is None:  # unreachable: both pipes are PIPE above
                return
            for raw in stream:
                line = raw.rstrip("\n")
                if keep:
                    self._stderr_tail.append(line)
                print(f"[voxtype daemon {name}] {line}", flush=True)

        threading.Thread(
            target=pump, args=(daemon.stdout, "stdout", False), daemon=True
        ).start()
        threading.Thread(
            target=pump, args=(daemon.stderr, "stderr", True), daemon=True
        ).start()

    def _daemon_exit_reason(self, daemon: subprocess.Popen[str]) -> str:
        tail = self._stderr_tail[-1] if self._stderr_tail else ""
        suffix = f": {tail}" if tail else ""
        return f"voxtype daemon exited (code {daemon.poll()}){suffix}"

    def _cleanup(self) -> None:
        """Kill daemon (TERM→KILL) and follow, drop the tmpdir. Idempotent."""
        with self._lock:
            if self._cleaned:
                return
            self._cleaned = True
            daemon = self._daemon
            follow = self._follow

        if daemon is not None and daemon.poll() is None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(daemon.pid, signal.SIGTERM)
            deadline = time.monotonic() + self._kill_grace_s
            while time.monotonic() < deadline and daemon.poll() is None:
                time.sleep(0.025)
            if daemon.poll() is None:
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(daemon.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                daemon.wait(timeout=10.0)
        if follow is not None and follow.poll() is None:
            follow.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                follow.wait(timeout=5.0)
            if follow.poll() is None:
                follow.kill()

        if self.runtime_dir is not None:
            shutil.rmtree(self.runtime_dir, ignore_errors=True)
        with _ACTIVE_LOCK:
            _ACTIVE.discard(self)
