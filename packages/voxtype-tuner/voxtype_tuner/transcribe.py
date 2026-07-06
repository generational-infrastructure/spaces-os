"""Run voxtype as a subprocess and recover the transcript from its stdout.

voxtype (whisper.cpp lineage) prints tracing/preamble lines before the
transcript. This module runs the built argv, strips that preamble, and returns
a :class:`TranscribeResult`. It never raises: subprocess failures, timeouts and
missing binaries are reported via the ``error`` field so the UI can surface them.
"""

from __future__ import annotations

import contextlib
import os
import re
import shlex
import signal
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from voxtype_tuner.params import (
    DEFAULT_NEMOTRON_MODEL,
    TranscribeParams,
    build_argv,
    nemotron_config_toml,
    nemotron_target_lang,
    parakeet_config_toml,
    whisper_config_toml,
)

# Sentinel returncode for failures where the process produced no exit status of
# its own (timeout kill, or the binary never launched).
_NO_EXIT_STATUS = -1

# Lines whose stripped form starts with one of these are voxtype's own tracing
# output, not transcript. Only consulted for the timestamp-free (plain/VAD)
# output shape. Kept as a tolerant prefix list so a slightly different real
# preamble still strips cleanly.
_PREAMBLE_PREFIXES: tuple[str, ...] = (
    "Loading audio file:",
    "Audio format:",
    "Resampling",
    "Processing",
    "VAD",
    "Detected language",
)

# Leading whisper segment-timestamp token, e.g. "[00:00:00.000 --> 00:00:03.200]".
# Anchored on the "-->" arrow so a bracketed transcript annotation such as
# "[MUSIC]" is never mistaken for a timestamp and the whole line dropped.
_TIMESTAMP_RE = re.compile(r"^\[\s*[\d:.]+\s*-->\s*[\d:.]+\s*\]\s*")

# ANSI SGR escape sequences (e.g. ESC[2m … ESC[0m, ESC[32m) that voxtype's
# tracing-subscriber wraps its colored log lines in. Stripped before any line
# analysis so a dimmed timestamp / green level word is recognised as a log.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# A tracing-subscriber log line leads with an RFC3339 timestamp
# (e.g. "2026-07-03T11:35:02.313489Z"), optionally followed by a level word.
# These are the app's own logs, never transcript, so the whole line is dropped,
# including the truncated quoted preview the "Transcription completed …: \"…\""
# line carries, which is NOT the transcript. Distinct from _TIMESTAMP_RE, which
# matches a bracketed whisper segment "[hh:mm:ss.xxx --> …]" that DOES carry text.
_LOG_LINE_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\b"
)


@dataclass
class TranscribeResult:
    text: str
    raw_stdout: str
    argv: list[str]
    returncode: int
    duration_s: float
    error: str | None
    # True when the run ended because the user's Stop cancelled it: a distinct
    # outcome the UI renders as "cancelled", never as success or failure.
    cancelled: bool = False


def _terminate_group_escalating(proc: subprocess.Popen[str], grace_s: float) -> None:
    """SIGTERM the child's whole process group, escalating to SIGKILL.

    The child leads its own group (``start_new_session=True``), so the group
    signal also reaches any helper the engine spawns. The escalation wait runs
    on a daemon thread because ``cancel()`` is called from the UI thread and
    must never block on a wedged child. The transcribe worker's ``communicate``
    is what actually observes the death and reaps.
    """
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGTERM)

    def escalate() -> None:
        deadline = time.monotonic() + grace_s
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.05)
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, signal.SIGKILL)

    threading.Thread(target=escalate, daemon=True).start()


class CancelHandle:
    """Cancellation for one in-flight transcribe subprocess.

    The UI thread calls :meth:`cancel`. The worker passes the handle into
    :func:`transcribe`, which attaches the live process. Whichever side is
    late still converges: cancelling before the spawn kills the process the
    moment it attaches, and cancelling after exit is a harmless no-op. The
    worker reports the run as ``cancelled`` based on the flag, so a kill can
    never masquerade as an ordinary failure.
    """

    def __init__(self, kill_grace_s: float = 2.0) -> None:
        self._lock = threading.Lock()
        self._proc: subprocess.Popen[str] | None = None
        self._cancelled = False
        self._kill_grace_s = kill_grace_s

    def cancel(self) -> None:
        with self._lock:
            already = self._cancelled
            self._cancelled = True
            proc = self._proc
        if not already and proc is not None:
            _terminate_group_escalating(proc, self._kill_grace_s)

    def cancelled(self) -> bool:
        with self._lock:
            return self._cancelled

    def attach(self, proc: subprocess.Popen[str]) -> None:
        """Bind the live subprocess (called by :func:`transcribe` only)."""
        with self._lock:
            self._proc = proc
            cancelled = self._cancelled
        if cancelled:
            _terminate_group_escalating(proc, self._kill_grace_s)


def _echo_subprocess(
    argv: list[str], returncode: int, stdout: str, stderr: str
) -> None:
    """Echo the raw voxtype call to the app's own stdout for terminal debugging.

    Purely a debug aid, additive to the parsed result: it mirrors the exact
    argv (copy-pasteable), the exit status, and the FULL stdout and stderr so a
    failing transcribe isn't opaque when the app is run from a terminal. Every
    line is prefixed so it's greppable and can't be mistaken for the transcript.
    """
    prefix = "[voxtype transcribe]"
    print(f"{prefix} argv: {shlex.join(argv)}", flush=True)
    print(f"{prefix} returncode: {returncode}", flush=True)
    for stream, text in (("stdout", stdout), ("stderr", stderr)):
        for line in text.splitlines():
            print(f"{prefix} {stream}: {line}", flush=True)


def _recover_transcript(stdout: str) -> str:
    """Recover the transcript from voxtype's stdout, dropping tracing/preamble.

    First strip ANSI colour codes and drop every tracing-subscriber log line
    (an RFC3339-timestamped, optionally levelled line, which carries model-load
    notes and a *truncated* quoted preview, never the transcript). What remains
    is voxtype's transcript, printed in one of two shapes. In *timestamped* mode
    every segment leads with a ``[start --> end]`` token, so when any is present
    those segments alone are the transcript, robust to unrecognised preamble
    lines. In *plain/VAD* mode the transcript is a bare, un-prefixed line (as in
    local whisper mode, which logs to stderr-style tracing then prints the plain
    sentence), so fall back to dropping known preamble prefixes.
    """
    lines: list[str] = []
    for raw in stdout.splitlines():
        line = _ANSI_RE.sub("", raw).strip()
        if not line or _LOG_LINE_RE.match(line):
            continue
        lines.append(line)
    segments = [_TIMESTAMP_RE.sub("", ln) for ln in lines if _TIMESTAMP_RE.match(ln)]
    if segments:
        return " ".join(seg.strip() for seg in segments).strip()
    kept = [ln for ln in lines if not ln.startswith(_PREAMBLE_PREFIXES)]
    return " ".join(kept).strip()


def transcribe(
    wav_path: str,
    p: TranscribeParams,
    voxtype_bin: str = "voxtype",
    timeout: float = 120.0,
    model_path: str | None = None,
    cancel: CancelHandle | None = None,
) -> TranscribeResult:
    """Run voxtype on ``wav_path`` with ``p``. Never raises.

    ``model_path`` pins the model to an absolute location (a system-provisioned
    store path, resolved by the caller's availability probe or, for nemotron,
    the Nix-provisioned model dir). Every engine takes such a path ONLY through a
    config file (whisper's ``--model`` flag validates names against its bundled
    catalog and silently drops a path), so a pinned (or inherently absolute)
    model routes through a generated ``-c`` config.
    """
    # parakeet and nemotron model selection lives ONLY in a [parakeet]/[nemotron]
    # config section (the top-level --model flag is whisper-only and drops their
    # names), so they always get a throwaway config, while whisper needs one exactly
    # when the model is path-pinned. The file must outlive the subprocess and be
    # removed once it returns, so its lifetime is bounded by the try/finally below.
    effective_path = model_path or (p.model if Path(p.model).is_absolute() else None)
    config_toml: str | None = None
    if p.engine == "parakeet":
        config_toml = parakeet_config_toml(p.model, path=effective_path)
    elif p.engine == "nemotron":
        # Pin the provisioned store dir into the mandatory [nemotron] section,
        # falling back to the registry name so a missing env yields voxtype's own
        # clear "model not found" rather than a `model = "None"` config. The
        # picker's language selection travels as nemotron's own single-target
        # target_lang locale (Auto → "auto"), the whisper --language flag being
        # ignored by this engine.
        config_toml = nemotron_config_toml(
            effective_path or DEFAULT_NEMOTRON_MODEL,
            target_lang=nemotron_target_lang(p.language),
            streaming=p.streaming,
        )
    elif p.engine == "whisper" and effective_path is not None:
        config_toml = whisper_config_toml(effective_path)

    config_path: str | None = None
    if config_toml is not None:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as fh:
            fh.write(config_toml)
            config_path = fh.name

    argv = build_argv(
        p,
        wav_path,
        voxtype_bin=voxtype_bin,
        config_path=config_path,
    )

    start = time.monotonic()
    try:
        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                # Own process group, so the Stop path's group signal reaches
                # any helper the engine spawns, not just the direct child.
                start_new_session=True,
            )
        except OSError as exc:
            # The launch never happened (missing/non-executable binary, ENOENT),
            # so there is no process stdout to parse. Echo the exact argv and the
            # error anyway: the success path echoes via _echo_subprocess below,
            # and a failed launch must not be the ONE outcome that prints nothing
            # to a terminal-run app (the original `voxtype-nemotron` ENOENT was
            # invisible for exactly this reason).
            _echo_subprocess(argv, _NO_EXIT_STATUS, "", str(exc))
            return TranscribeResult(
                text="",
                raw_stdout="",
                argv=argv,
                returncode=_NO_EXIT_STATUS,
                duration_s=time.monotonic() - start,
                error=str(exc),
            )
        if cancel is not None:
            cancel.attach(proc)
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                # Reap the killed child so it doesn't linger as a zombie.
                proc.communicate(timeout=10.0)
            # exc.stdout is typed bytes | str | None. With text=True it is
            # str, but coerce defensively so partial output survives.
            partial = exc.stdout if isinstance(exc.stdout, str) else ""
            return TranscribeResult(
                text="",
                raw_stdout=partial,
                argv=argv,
                returncode=_NO_EXIT_STATUS,
                duration_s=time.monotonic() - start,
                error=f"timeout after {timeout:g}s",
            )
    finally:
        # Remove the temp config on every exit path (success, nonzero, timeout,
        # OSError) so a run never leaks a config into the temp dir.
        if config_path is not None:
            with contextlib.suppress(OSError):
                Path(config_path).unlink()

    duration_s = time.monotonic() - start
    _echo_subprocess(argv, proc.returncode, stdout, stderr)

    if cancel is not None and cancel.cancelled():
        # The Stop path killed this run on purpose: report the distinct
        # cancelled outcome, never a success (even if the exit raced to 0)
        # and never an ordinary failure the UI would tint destructive.
        return TranscribeResult(
            text="",
            raw_stdout=stdout,
            argv=argv,
            returncode=proc.returncode,
            duration_s=duration_s,
            error="cancelled",
            cancelled=True,
        )

    error: str | None = None
    if proc.returncode != 0:
        error = stderr.strip() or f"voxtype exited with code {proc.returncode}"

    return TranscribeResult(
        text=_recover_transcript(stdout),
        raw_stdout=stdout,
        argv=argv,
        returncode=proc.returncode,
        duration_s=duration_s,
        error=error,
    )
