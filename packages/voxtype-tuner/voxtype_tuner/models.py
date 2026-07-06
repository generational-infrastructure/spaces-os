"""Download the selected voxtype model and detect whether it is already present.

The tuner shells out to voxtype's own non-interactive downloader
(``voxtype setup --download --model <NAME> --quiet``) rather than fetching
weights itself, so the on-disk layout always matches what the engine expects at
transcribe time. Presence detection mirrors ``run_setup``'s own checks: a single
``ggml-<model>.bin`` file for whisper, a ``<model>/`` subdirectory for parakeet.

Like :mod:`voxtype_tuner.transcribe`, this never raises: a missing binary, a
timeout or a nonzero exit is reported through :class:`DownloadResult` so the UI
can surface it in the status label. The ``--engine`` flag is deliberately never
passed: ``run_setup`` derives the engine from the model name, and the whisper
and parakeet name spaces are disjoint, so passing it would be redundant at best.
"""

from __future__ import annotations

import contextlib
import os
import shlex
import shutil
import signal
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:
    from collections.abc import Callable, Mapping

    from voxtype_tuner.transcribe import CancelHandle

# Sentinel returncode for failures where the process produced no exit status of
# its own (timeout kill, or the binary never launched), matching transcribe.py.
_NO_EXIT_STATUS = -1

# Keep only the tail of stderr for the "failed: <short>" label. A full download
# log can be thousands of lines.
_STDERR_TAIL_LINES = 20


def _echo_subprocess(
    argv: list[str], returncode: int, stdout: str, stderr: str
) -> None:
    """Echo the raw voxtype call to the app's own stdout for terminal debugging.

    Mirrors :func:`voxtype_tuner.transcribe._echo_subprocess`: additive to the
    parsed result, it prints the exact argv (copy-pasteable), the exit status,
    and the FULL stdout and stderr so a stalled or failed download isn't opaque
    when the app is run from a terminal. Every line is prefixed so it's
    greppable and can't be mistaken for other output.
    """
    prefix = "[voxtype download]"
    print(f"{prefix} argv: {shlex.join(argv)}", flush=True)
    print(f"{prefix} returncode: {returncode}", flush=True)
    for stream, text in (("stdout", stdout), ("stderr", stderr)):
        for line in text.splitlines():
            print(f"{prefix} {stream}: {line}", flush=True)


def models_dir() -> str:
    """Return voxtype's models directory.

    ``$XDG_DATA_HOME/voxtype/models`` when ``XDG_DATA_HOME`` is set to an
    absolute path (matching the Rust ``directories`` crate), else the
    ``~/.local/share/voxtype/models`` fallback. ``Path.expanduser`` is used
    for the home leg so tests can pin it by monkeypatching ``HOME``.
    """
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg and Path(xdg).is_absolute():
        base = Path(xdg)
    else:
        base = Path("~").expanduser() / ".local" / "share"
    return str(base / "voxtype" / "models")


AvailabilityState = Literal["user", "system", "absent"]


@dataclass(frozen=True)
class ModelAvailability:
    """Where the selected model's bytes are, and how transcribe must reach them.

    ``path`` is set only for ``system``: the absolute, config-provided location
    that transcribe must pass through a generated config (voxtype's name lookup
    only searches the user models dir). ``user`` models resolve by name.
    """

    state: AvailabilityState
    path: str | None = None


def model_availability(
    engine: str,
    model: str,
    system_paths: Mapping[tuple[str, str], str] | None = None,
) -> ModelAvailability:
    """Three-state probe for the selected (engine, model).

    - ``user``: the user models dir holds it, ``ggml-<model>.bin`` for whisper
      (the name is embedded verbatim, dots and dashes included), a ``<model>/``
      subdirectory for parakeet, mirroring ``run_setup``'s own checks. A user
      model transcribes by NAME, so no path is reported.
    - ``system``: a config maps this model to an absolute path that exists:
      either the model value itself is absolute (how voxtype configs pin custom
      weights) or ``system_paths`` carries a (engine, model) -> path entry (the
      NixOS module's store-path provisioning, extracted by defaults.py). The
      probe keys purely on those config values, never on a path *looking* like
      a store path. ``path`` is the location transcribe must pass through a
      generated config, since voxtype's name lookup only searches the user dir.
    - ``absent``: neither, including a mapped path whose bytes are gone.

    The user dir wins when both hold the model: that is what a name-based
    transcribe resolves to, so caption and argv stay in agreement. Engines
    without on-disk models (nemotron, unknown) are always ``absent``.
    """
    if engine not in ("whisper", "parakeet") or not model:
        return ModelAvailability(state="absent")

    def present(path: Path) -> bool:
        # is_file() follows symlinks, so store-path-prefetched models linked in
        # under the expected name correctly read as present.
        return path.is_file() if engine == "whisper" else path.is_dir()

    if Path(model).is_absolute():
        if present(Path(model)):
            return ModelAvailability(state="system", path=model)
        return ModelAvailability(state="absent")
    root = Path(models_dir())
    user_path = root / f"ggml-{model}.bin" if engine == "whisper" else root / model
    if present(user_path):
        return ModelAvailability(state="user")
    mapped = (system_paths or {}).get((engine, model))
    if mapped is not None and present(Path(mapped)):
        return ModelAvailability(state="system", path=mapped)
    return ModelAvailability(state="absent")


def model_present(engine: str, model: str) -> bool:
    """Boolean view of :func:`model_availability`: is the model on disk at all?"""
    return model_availability(engine, model).state != "absent"


def build_download_argv(
    model: str, voxtype_bin: str = "voxtype", quiet: bool = True
) -> list[str]:
    """Build voxtype's non-interactive download invocation for ``model``.

    ``--download``/``--model``/``--quiet`` are flags on the ``setup`` subcommand
    itself (action ``None``), so they follow ``setup``. This routes to
    ``run_setup(download=true, model_override=Some(model), quiet=…)``. It is
    *not* ``setup model --download`` (that is the interactive stdin picker).
    ``--engine`` is intentionally omitted. See the module docstring.
    """
    argv = [voxtype_bin, "setup", "--download", "--model", model]
    if quiet:
        argv.append("--quiet")
    return argv


_MIB = 1024 * 1024

# Expected download sizes, mirroring voxtype's own registry
# (src/setup/model.rs). Whisper carries display-grade size_mb values there
# (approximate, which is why the percent math below never claims 100%), while
# the parakeet entries are the exact per-file expected_size_bytes sums.
_WHISPER_SIZE_MB: dict[str, int] = {
    "tiny": 75,
    "tiny.en": 39,
    "base": 142,
    "base.en": 142,
    "small": 466,
    "small.en": 466,
    "medium": 1500,
    "medium.en": 1500,
    "large-v3": 3100,
    "large-v3-turbo": 1600,
}
_PARAKEET_TOTAL_BYTES: dict[str, int] = {
    "parakeet-tdt-0.6b-v2": 41_770_866 + 2_435_420_160 + 35_792_059 + 9_384 + 97,
    "parakeet-tdt-0.6b-v2-int8": 652_184_014 + 8_998_286 + 9_384 + 97,
    "parakeet-tdt-0.6b-v3": 43_825_971 + 2_620_260_352 + 76_023_939 + 96_179 + 97,
    "parakeet-tdt-0.6b-v3-int8": 683_671_552 + 19_087_667 + 96_179 + 97,
    "parakeet-unified-en-0.6b": (
        43_878_400 + 2_617_245_696 + 37_537_792 + 257_024 + 5_164
    ),
}


@dataclass(frozen=True)
class DownloadProgress:
    """One byte-count sample of an in-flight download."""

    done_bytes: int
    total_bytes: int | None

    @property
    def percent(self) -> int | None:
        """0..99, or ``None`` without a known total.

        Clamped below 100 because the whisper totals are display-grade
        approximations: completion is the process exit status's call, never
        the byte math's.
        """
        if not self.total_bytes or self.total_bytes <= 0:
            return None
        return min(99, max(0, self.done_bytes * 100 // self.total_bytes))


def download_total_bytes(engine: str, model: str) -> int | None:
    """The expected artifact size for a catalog model, ``None`` off-catalog."""
    if engine == "whisper":
        mb = _WHISPER_SIZE_MB.get(model)
        return None if mb is None else mb * _MIB
    if engine == "parakeet":
        return _PARAKEET_TOTAL_BYTES.get(model)
    return None


def _artifact_bytes(engine: str, model: str) -> int:
    """Bytes of the in-flight artifact on disk right now.

    Meaningful mid-download because voxtype's downloader writes straight into
    the final location (it hands curl ``-o <dest>``: the ggml file for
    whisper, per-manifest files inside the model dir for parakeet), so the
    destination grows as the fetch proceeds. Races with the writer are
    harmless: a partially-visible size is still monotone progress.
    """
    root = Path(models_dir())
    if engine == "whisper":
        target = (
            Path(model) if Path(model).is_absolute() else root / f"ggml-{model}.bin"
        )
        try:
            return target.stat().st_size
        except OSError:
            return 0
    if engine == "parakeet":
        target = Path(model) if Path(model).is_absolute() else root / model
        total = 0
        try:
            entries = list(os.scandir(target))
        except OSError:
            return 0
        for entry in entries:
            try:
                if entry.is_file(follow_symlinks=True):
                    total += entry.stat().st_size
            except OSError:
                continue
        return total
    return 0


@dataclass
class DownloadResult:
    ok: bool
    returncode: int
    stderr_tail: str
    error: str | None
    # True only when a caller's cancel request actually killed the subprocess
    # before it completed. A cancel that loses the race to a clean exit
    # reports ok=True with this False, so the two outcomes stay exclusive.
    cancelled: bool = False


def _terminate_group(proc: subprocess.Popen[str]) -> None:
    """SIGKILL the child's whole process group, then reap it.

    The child was started with ``start_new_session=True``, so it leads its own
    process group (pgid == pid) and voxtype's ``curl`` grandchild lives in that
    same group. Signalling the group (not just the child) takes the grandchild
    down too, so it can't keep writing into the model dir and race the next
    attempt. Best-effort: a group that already exited raises ``ProcessLookupError``.
    """
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(proc.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        # Reap the child so it doesn't linger as a zombie. The group is already
        # signalled, so this returns promptly.
        proc.communicate(timeout=10.0)


def _remove_partial_artifact(engine: str, model: str) -> None:
    """Delete the destination artifact of a download that did not complete.

    voxtype's downloader writes straight into the final location and
    :func:`model_availability` keys purely on that path existing, so partial
    bytes left by a cancelled, failed or timed-out fetch would make the model
    read "ready" while being a truncated file. Whisper's artifact is the
    single ggml file, while parakeet's is the whole model directory, where is_dir()
    is true from the first partial manifest file, so the entire tree must go.
    Only called once the subprocess is known dead without a clean exit, so it
    can neither race the writer nor delete a completed download.
    """
    root = Path(models_dir())
    if engine == "whisper":
        target = (
            Path(model) if Path(model).is_absolute() else root / f"ggml-{model}.bin"
        )
        with contextlib.suppress(OSError):
            target.unlink(missing_ok=True)
    elif engine == "parakeet":
        target = Path(model) if Path(model).is_absolute() else root / model
        shutil.rmtree(target, ignore_errors=True)


def download_model(
    engine: str,
    model: str,
    voxtype_bin: str = "voxtype",
    quiet: bool = True,
    timeout: float = 3600.0,
    on_progress: Callable[[DownloadProgress], None] | None = None,
    progress_interval: float = 0.5,
    cancel: CancelHandle | None = None,
) -> DownloadResult:
    """Download ``model`` via voxtype's setup downloader. Never raises.

    nemotron (whose model is Nix-provisioned, so voxtype ships no first-use
    downloader for it) and an empty model are refused up front with ``ok=False``
    and no subprocess. Otherwise the built
    argv is run. ``ok`` is ``returncode == 0``. A ``TimeoutExpired``/``OSError``
    is folded into ``ok=False`` with the sentinel returncode and ``error`` set.

    voxtype writes model files in place with no lock, and on timeout its ``curl``
    grandchild (which is NOT the direct child) survives a naive child-only kill
    and keeps writing into the model dir, corrupting the user's next attempt
    (the ``Failed to hash …onnx.data: No such file or directory`` race). So the
    child is launched in its own session/process group and a timeout kills the
    WHOLE group. The default is one hour: the ~2.5 GB full-precision models are
    genuinely slow to fetch on a poor line, and the timeout message tracks it.

    ``cancel`` is the same :class:`~voxtype_tuner.transcribe.CancelHandle`
    stop idiom the batch transcribe uses: the UI thread calls ``cancel()``,
    which SIGTERMs the attached process group with a SIGKILL escalation, and
    the blocking ``communicate`` below observes the death and reaps. One
    deliberate difference from transcribe's outcome rule: a download persists
    an artifact, so the child's exit status (not the request) decides the
    race. A cancelled child that still exited 0 completed its download before
    the signal landed. That is reported ``ok`` and the artifact is kept.
    Every abandoned in-flight write (cancel kill, nonzero exit, timeout)
    removes the partial destination artifact: the downloader targets the
    final path directly and :func:`model_availability` keys on that path
    existing, so a leaked partial would masquerade as a ready model.

    ``on_progress`` is sampled every ``progress_interval`` seconds from a
    dedicated poller thread (so it is called OFF the caller's thread) by
    watching the destination artifact grow, since voxtype itself only renders a
    curl progress bar, nothing parseable. The poller is joined before this
    function returns on every path, so no sample can arrive after the result.
    """
    if engine == "nemotron":
        return DownloadResult(
            ok=False,
            returncode=_NO_EXIT_STATUS,
            stderr_tail="",
            error="nemotron's model is system-provisioned, nothing to download",
        )
    if not model:
        return DownloadResult(
            ok=False,
            returncode=_NO_EXIT_STATUS,
            stderr_tail="",
            error="no model selected",
        )

    def discard_partial() -> None:
        # Only an artifact this run brought into being can be a partial:
        # never delete bytes that predate the fetch, so a re-download that
        # fails without writing (refused, no disk, bad permissions) can't
        # destroy a working model. The tuner itself only downloads absent
        # models. This guards direct callers of the module API.
        if not pre_existing:
            _remove_partial_artifact(engine, model)

    pre_existing = model_present(engine, model)
    argv = build_download_argv(model, voxtype_bin=voxtype_bin, quiet=quiet)
    try:
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
    except OSError as exc:
        return DownloadResult(
            ok=False,
            returncode=_NO_EXIT_STATUS,
            stderr_tail="",
            error=str(exc),
        )

    if cancel is not None:
        # Whichever side is late converges: a cancel already requested kills
        # the group the moment it attaches. A later cancel kills it live.
        cancel.attach(proc)

    stop_polling = threading.Event()
    poller: threading.Thread | None = None
    if on_progress is not None:
        total = download_total_bytes(engine, model)
        hook = on_progress

        def poll() -> None:
            while not stop_polling.wait(progress_interval):
                hook(DownloadProgress(_artifact_bytes(engine, model), total))

        poller = threading.Thread(target=poll, daemon=True)
        poller.start()

    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _terminate_group(proc)
        discard_partial()
        return DownloadResult(
            ok=False,
            returncode=_NO_EXIT_STATUS,
            stderr_tail="",
            error=f"timeout after {timeout:g}s",
        )
    finally:
        # Stop the poller before any partial-artifact cleanup, so no sample
        # can observe (and report) the destination vanishing.
        stop_polling.set()
        if poller is not None:
            poller.join()

    _echo_subprocess(argv, proc.returncode, stdout, stderr)

    if cancel is not None and cancel.cancelled() and proc.returncode != 0:
        # The Stop path's kill landed before a clean exit. A cancelled child
        # that still exited 0 falls through instead: its download is complete
        # and the artifact must be kept. See the docstring's race rule.
        discard_partial()
        return DownloadResult(
            ok=False,
            returncode=proc.returncode,
            stderr_tail="",
            error="cancelled",
            cancelled=True,
        )

    tail = "\n".join(stderr.strip().splitlines()[-_STDERR_TAIL_LINES:])
    ok = proc.returncode == 0
    if not ok:
        discard_partial()
    return DownloadResult(
        ok=ok,
        returncode=proc.returncode,
        stderr_tail=tail,
        error=None if ok else (tail or f"voxtype exited with {proc.returncode}"),
    )
