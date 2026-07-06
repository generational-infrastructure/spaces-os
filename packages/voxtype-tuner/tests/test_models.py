"""Tests for the in-app model downloader.

These exercise the real code path: a tiny shell script stands in for the
voxtype binary and, on ``setup --download --model <name>``, creates the exact
on-disk artifact voxtype's own ``run_setup`` presence check looks for, so
``model_present`` genuinely flips ``False -> True`` against the tmp models dir.
No network, no display, no audio device involved.
"""

import inspect
import os
import threading
import time
from collections.abc import Callable
from pathlib import Path

import pytest
from voxtype_tuner.models import (
    DownloadProgress,
    DownloadResult,
    ModelAvailability,
    build_download_argv,
    download_model,
    download_total_bytes,
    model_availability,
    model_present,
    models_dir,
)
from voxtype_tuner.transcribe import CancelHandle

# whisper fake: turn "setup --download --model <name>" into the single
# ggml-<name>.bin file run_setup checks for, then exit 0.
_WHISPER_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
: > "$dir/ggml-$model.bin"
exit 0
"""

# parakeet fake: create the per-model subdirectory (with a dummy weight file)
# that run_setup checks via models_dir.join(model).exists().
_PARAKEET_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$XDG_DATA_HOME/voxtype/models/$model"
mkdir -p "$dir"
: > "$dir/encoder-model.onnx"
exit 0
"""

# failure fake: emit a realistic download error on stderr and bail nonzero.
_FAILURE_FAKE = """\
#!/usr/bin/env bash
echo "boom: network unreachable" >&2
exit 1
"""

# tripwire fake: creates a sentinel file if ever executed, so a test can prove
# the nemotron/empty guard never spawned a process.
_TRIPWIRE_FAKE = """\
#!/usr/bin/env bash
: > "$TRIPWIRE_PATH"
exit 3
"""


def _write_fake(tmp_path: Path, name: str, body: str) -> str:
    script = tmp_path / name
    script.write_text(body)
    script.chmod(0o755)
    return str(script)


def _use_tmp_data_home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg"))


def test_build_download_argv_exact_and_no_engine() -> None:
    assert build_download_argv("tiny", "vox", quiet=True) == [
        "vox",
        "setup",
        "--download",
        "--model",
        "tiny",
        "--quiet",
    ]
    # A future refactor must never re-add --engine on the download path: the
    # engine is picked from the model name by run_setup.
    assert "--engine" not in build_download_argv("tiny", "vox", quiet=True)


def test_build_download_argv_omits_quiet_when_disabled() -> None:
    argv = build_download_argv("large-v3", "vox", quiet=False)
    assert argv == ["vox", "setup", "--download", "--model", "large-v3"]
    assert "--quiet" not in argv


def test_whisper_download_flips_presence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _WHISPER_FAKE)

    assert model_present("whisper", "tiny") is False

    result = download_model("whisper", "tiny", voxtype_bin=fake)

    assert result.ok is True
    assert result.returncode == 0
    assert result.error is None
    assert model_present("whisper", "tiny") is True
    assert (Path(models_dir()) / "ggml-tiny.bin").is_file()


def test_whisper_download_preserves_dotted_name(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The model name is embedded verbatim, dots included: base.en ->
    # ggml-base.en.bin, not ggml-base.bin.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _WHISPER_FAKE)

    download_model("whisper", "base.en", voxtype_bin=fake)

    assert (Path(models_dir()) / "ggml-base.en.bin").is_file()
    assert model_present("whisper", "base.en") is True


def test_parakeet_download_flips_presence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _PARAKEET_FAKE)
    model = "parakeet-tdt-0.6b-v3"

    assert model_present("parakeet", model) is False

    result = download_model("parakeet", model, voxtype_bin=fake)

    assert result.ok is True
    assert model_present("parakeet", model) is True
    assert (Path(models_dir()) / model).is_dir()


def test_download_failure_reports_error_and_leaves_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _FAILURE_FAKE)

    result = download_model("whisper", "tiny", voxtype_bin=fake)

    assert result.ok is False
    assert result.returncode != 0
    assert result.stderr_tail != ""
    assert "network unreachable" in result.stderr_tail
    assert result.error is not None
    assert model_present("whisper", "tiny") is False


def test_download_missing_binary_reports_oserror(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    missing = str(tmp_path / "does-not-exist")

    result = download_model("whisper", "tiny", voxtype_bin=missing)

    assert result.ok is False
    assert result.returncode == -1
    assert result.error is not None


def test_download_timeout_uses_sentinel_returncode(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", "#!/usr/bin/env bash\nsleep 5\n")

    result = download_model("whisper", "tiny", voxtype_bin=fake, timeout=0.2)

    assert result.ok is False
    assert result.returncode == -1
    assert result.error is not None
    assert "timeout" in result.error.lower()


# grandchild fake: voxtype spawns a `curl` grandchild that, without a process
# group, outlives a parent-only kill and keeps writing into the model dir,
# racing the user's next attempt. This models it: spawn a long sleep in the
# background, record its pid, then block so the parent times out.
_GRANDCHILD_FAKE = """\
#!/usr/bin/env bash
sleep 300 &
echo $! > "$PIDFILE"
wait
"""


def test_download_timeout_group_kills_grandchild(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # On timeout the whole process GROUP must die, not just voxtype: a surviving
    # curl grandchild is exactly what corrupts the model dir on the next attempt.
    _use_tmp_data_home(monkeypatch, tmp_path)
    pidfile = tmp_path / "grandchild.pid"
    monkeypatch.setenv("PIDFILE", str(pidfile))
    fake = _write_fake(tmp_path, "voxtype", _GRANDCHILD_FAKE)

    result = download_model("whisper", "tiny", voxtype_bin=fake, timeout=0.5)

    assert result.ok is False
    assert result.returncode == -1
    assert "timeout" in (result.error or "").lower()

    # The grandchild recorded its pid before blocking. It must now be dead
    # (reaped after the group SIGKILL), so signalling it raises ProcessLookupError.
    pid = int(pidfile.read_text().strip())
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        pytest.fail(f"grandchild pid {pid} survived the group kill")


# slow-partial fake: write a truncated artifact into the FINAL destination
# (exactly how voxtype's curl -o behaves), then block for minutes. Whatever
# interrupts it (cancel, timeout) leaves that partial file behind unless the
# downloader cleans up, and model_availability keys purely on the path
# existing, so a leaked partial reads as "ready".
_SLOW_PARTIAL_WHISPER_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
head -c 1000 /dev/zero > "$dir/ggml-$model.bin"
sleep 300
"""

# parakeet flavor: the artifact is the model DIRECTORY, and is_dir() is true
# from the first partial manifest file, an even easier "ready" lie to leave.
_SLOW_PARTIAL_PARAKEET_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$XDG_DATA_HOME/voxtype/models/$model"
mkdir -p "$dir"
head -c 1000 /dev/zero > "$dir/encoder-model.onnx"
sleep 300
"""

# partial-then-fail fake: a mid-stream network death, bytes already in the
# destination, nonzero exit.
_PARTIAL_FAILURE_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
head -c 1000 /dev/zero > "$dir/ggml-$model.bin"
echo "boom: connection reset mid-transfer" >&2
exit 1
"""


def _download_in_thread(
    engine: str, model: str, fake: str, cancel: CancelHandle
) -> tuple[threading.Thread, list[DownloadResult]]:
    """Run download_model off-thread the way the app's worker does."""
    box: list[DownloadResult] = []

    def work() -> None:
        box.append(download_model(engine, model, voxtype_bin=fake, cancel=cancel))

    thread = threading.Thread(target=work, daemon=True)
    thread.start()
    return thread, box


def _wait_for(pred: Callable[[], bool], timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return False


def test_cancel_mid_download_cleans_partial_and_stays_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # THE cancel invariant: the downloader writes straight into the final
    # destination and model_availability keys on that path existing, so a
    # cancelled fetch must remove the truncated artifact, otherwise the model
    # reads "ready" while being an unusable partial file.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _SLOW_PARTIAL_WHISPER_FAKE)
    partial = Path(models_dir()) / "ggml-tiny.bin"

    cancel = CancelHandle()
    thread, box = _download_in_thread("whisper", "tiny", fake, cancel)
    assert _wait_for(partial.is_file), "fake never wrote the partial artifact"

    cancel.cancel()
    thread.join(timeout=10.0)
    assert not thread.is_alive(), "cancel did not stop the download worker"

    result = box[0]
    assert result.ok is False
    assert result.cancelled is True
    assert partial.exists() is False
    assert model_availability("whisper", "tiny").state == "absent"
    assert model_present("whisper", "tiny") is False


def test_cancel_mid_download_removes_partial_parakeet_dir(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The parakeet artifact is a directory that reads present from its FIRST
    # partial manifest file, so cleanup must remove the whole tree, not one file.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _SLOW_PARTIAL_PARAKEET_FAKE)
    model = "parakeet-tdt-0.6b-v3"
    partial_dir = Path(models_dir()) / model

    cancel = CancelHandle()
    thread, box = _download_in_thread("parakeet", model, fake, cancel)
    assert _wait_for(partial_dir.is_dir), "fake never created the partial model dir"

    cancel.cancel()
    thread.join(timeout=10.0)
    assert not thread.is_alive()

    assert box[0].cancelled is True
    assert partial_dir.exists() is False
    assert model_availability("parakeet", model).state == "absent"


def test_cancel_kills_the_whole_process_group(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Cancel must take down voxtype's curl grandchild too (same reasoning as
    # the timeout group kill): a surviving writer would keep growing the
    # artifact after its cleanup and corrupt the user's next attempt.
    _use_tmp_data_home(monkeypatch, tmp_path)
    pidfile = tmp_path / "grandchild.pid"
    monkeypatch.setenv("PIDFILE", str(pidfile))
    fake = _write_fake(tmp_path, "voxtype", _GRANDCHILD_FAKE)

    cancel = CancelHandle()
    thread, box = _download_in_thread("whisper", "tiny", fake, cancel)
    assert _wait_for(pidfile.is_file), "fake never recorded its grandchild pid"

    cancel.cancel()
    thread.join(timeout=10.0)
    assert not thread.is_alive()
    assert box[0].cancelled is True

    pid = int(pidfile.read_text().strip())
    assert _wait_for(lambda: not _pid_alive(pid)), (
        f"grandchild pid {pid} survived the cancel kill"
    )


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_cancel_escalates_to_kill_when_term_is_ignored(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # terminate → kill escalation: a child that shrugs off SIGTERM (curl mid
    # rename, a wedged voxtype) must still die via SIGKILL after the grace
    # period, and the partial artifact must still be cleaned up.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(
        tmp_path,
        "voxtype",
        """\
#!/usr/bin/env bash
trap '' TERM
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
head -c 1000 /dev/zero > "$dir/ggml-tiny.bin"
while true; do sleep 0.1; done
""",
    )
    partial = Path(models_dir()) / "ggml-tiny.bin"

    cancel = CancelHandle()
    thread, box = _download_in_thread("whisper", "tiny", fake, cancel)
    assert _wait_for(partial.is_file)

    cancel.cancel()
    thread.join(timeout=15.0)
    assert not thread.is_alive(), "SIGKILL escalation never fired"

    assert box[0].cancelled is True
    assert partial.exists() is False


def test_cancel_after_natural_completion_keeps_the_artifact(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The completed-vs-cancelled race must resolve deterministically from the
    # child's actual exit status: a cancel whose signal lands only after the
    # download already finished cleanly reports COMPLETED and must never
    # delete the fully-downloaded artifact. The fake ignores SIGTERM and
    # always exits 0, so this pins the returncode==0 guard, not scheduling luck.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(
        tmp_path,
        "voxtype",
        """\
#!/usr/bin/env bash
trap '' TERM
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
head -c 5000 /dev/zero > "$dir/ggml-tiny.bin"
sleep 0.4
exit 0
""",
    )
    artifact = Path(models_dir()) / "ggml-tiny.bin"

    cancel = CancelHandle()
    thread, box = _download_in_thread("whisper", "tiny", fake, cancel)
    assert _wait_for(artifact.is_file)

    cancel.cancel()  # lands mid-sleep, TERM is ignored, and the child exits 0 anyway
    thread.join(timeout=10.0)
    assert not thread.is_alive()

    result = box[0]
    assert result.cancelled is False
    assert result.ok is True
    assert artifact.is_file()
    assert artifact.stat().st_size == 5000
    assert model_present("whisper", "tiny") is True


def test_failed_download_removes_partial_artifact(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Same bug class as cancel: a mid-stream failure has already written bytes
    # into the final destination. Leaking them makes the very next
    # model_availability probe claim "ready" for a truncated file.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _PARTIAL_FAILURE_FAKE)
    partial = Path(models_dir()) / "ggml-tiny.bin"

    result = download_model("whisper", "tiny", voxtype_bin=fake)

    assert result.ok is False
    assert "connection reset" in result.stderr_tail
    assert partial.exists() is False
    assert model_availability("whisper", "tiny").state == "absent"


def test_timed_out_download_removes_partial_artifact(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The timeout kill is the third path that abandons an in-flight write. It
    # must clean up like cancel and failure do.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _SLOW_PARTIAL_WHISPER_FAKE)
    partial = Path(models_dir()) / "ggml-tiny.bin"

    result = download_model("whisper", "tiny", voxtype_bin=fake, timeout=0.5)

    assert result.ok is False
    assert "timeout" in (result.error or "").lower()
    assert partial.exists() is False
    assert model_availability("whisper", "tiny").state == "absent"


def test_failed_redownload_never_deletes_a_preexisting_artifact(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The partial cleanup only covers artifacts THIS run brought into being:
    # a re-download over an already-present model (a direct module caller,
    # since the tuner itself only downloads absent models) that fails without
    # writing must not destroy the working weights.
    _use_tmp_data_home(monkeypatch, tmp_path)
    root = Path(models_dir())
    root.mkdir(parents=True)
    (root / "ggml-tiny.bin").write_bytes(b"ggml-good-weights")
    fake = _write_fake(tmp_path, "voxtype", _FAILURE_FAKE)

    result = download_model("whisper", "tiny", voxtype_bin=fake)

    assert result.ok is False
    assert (root / "ggml-tiny.bin").read_bytes() == b"ggml-good-weights"
    assert model_present("whisper", "tiny") is True


def test_default_download_timeout_is_one_hour() -> None:
    # The multi-GB full-precision models need well over the old 1800s on a slow
    # line. The default is bumped to 3600s and the timeout message tracks it.
    default = inspect.signature(download_model).parameters["timeout"].default
    assert default == 3600.0


def test_models_dir_honours_absolute_xdg(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("XDG_DATA_HOME", "/abs/data")
    assert models_dir() == "/abs/data/voxtype/models"


def test_models_dir_falls_back_to_home_when_xdg_unset(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert models_dir() == str(tmp_path / ".local" / "share" / "voxtype" / "models")


def test_models_dir_falls_back_when_xdg_relative(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # A non-absolute XDG_DATA_HOME is invalid per the spec. Fall back to HOME.
    monkeypatch.setenv("XDG_DATA_HOME", "relative/data")
    monkeypatch.setenv("HOME", str(tmp_path))
    assert models_dir() == str(tmp_path / ".local" / "share" / "voxtype" / "models")


def test_nemotron_refused_without_spawning_process(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    tripwire = tmp_path / "ran"
    monkeypatch.setenv("TRIPWIRE_PATH", str(tripwire))
    fake = _write_fake(tmp_path, "voxtype", _TRIPWIRE_FAKE)

    result = download_model("nemotron", "", voxtype_bin=fake)

    assert result.ok is False
    assert result.error is not None
    assert tripwire.exists() is False


def test_empty_model_refused_without_spawning_process(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    tripwire = tmp_path / "ran"
    monkeypatch.setenv("TRIPWIRE_PATH", str(tripwire))
    fake = _write_fake(tmp_path, "voxtype", _TRIPWIRE_FAKE)

    result = download_model("whisper", "", voxtype_bin=fake)

    assert result.ok is False
    assert result.error is not None
    assert tripwire.exists() is False


def test_unknown_engine_never_present(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    assert model_present("wobble", "anything") is False


def test_whisper_absolute_path_model_probes_that_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The system defaults can seed a whisper model as an absolute store path
    # (the NixOS module's fetchurl reference). Presence is then a probe of
    # that exact file, never a ggml-<path>.bin lookup in the models dir.
    _use_tmp_data_home(monkeypatch, tmp_path)
    weights = tmp_path / "abc123-ggml-small.bin"

    assert model_present("whisper", str(weights)) is False

    weights.write_bytes(b"ggml")
    assert model_present("whisper", str(weights)) is True


def test_parakeet_absolute_path_model_probes_that_directory(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # parakeet.model may likewise be an absolute model *directory*.
    _use_tmp_data_home(monkeypatch, tmp_path)
    model_dir = tmp_path / "parakeet-custom"

    assert model_present("parakeet", str(model_dir)) is False

    model_dir.mkdir()
    assert model_present("parakeet", str(model_dir)) is True


def test_availability_absent_when_nothing_on_disk(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)

    got = model_availability("whisper", "tiny")

    assert got == ModelAvailability(state="absent", path=None)


def test_availability_user_when_model_in_user_dir(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)
    root = Path(models_dir())
    root.mkdir(parents=True)
    (root / "ggml-tiny.bin").write_bytes(b"ggml")

    got = model_availability("whisper", "tiny")

    assert got.state == "user"
    # A user-dir model transcribes by NAME (voxtype resolves it itself), so no
    # path override is reported.
    assert got.path is None


def test_availability_system_when_config_maps_name_to_existing_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The probe keys on the config-provided mapping, never on a literal
    # /nix/store prefix: a store-like path fabricated under tmp_path must work.
    _use_tmp_data_home(monkeypatch, tmp_path)
    weights = tmp_path / "nix-store" / "abc123-ggml-small.bin"
    weights.parent.mkdir()
    weights.write_bytes(b"ggml")

    got = model_availability(
        "whisper", "small", system_paths={("whisper", "small"): str(weights)}
    )

    assert got == ModelAvailability(state="system", path=str(weights))


def test_availability_system_requires_the_mapped_path_to_exist(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # A GC'd (or mistyped) store path provides no bytes: claiming "ready
    # (system)" for it would offer a transcribe that can only fail.
    _use_tmp_data_home(monkeypatch, tmp_path)

    got = model_availability(
        "whisper",
        "small",
        system_paths={("whisper", "small"): str(tmp_path / "gone-ggml-small.bin")},
    )

    assert got.state == "absent"


def test_availability_user_wins_over_system(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # With both present, the user download is what a name-based transcribe
    # resolves to. Report that, so caption and argv agree.
    _use_tmp_data_home(monkeypatch, tmp_path)
    root = Path(models_dir())
    root.mkdir(parents=True)
    (root / "ggml-small.bin").write_bytes(b"ggml")
    weights = tmp_path / "abc123-ggml-small.bin"
    weights.write_bytes(b"ggml")

    got = model_availability(
        "whisper", "small", system_paths={("whisper", "small"): str(weights)}
    )

    assert got.state == "user"


def test_availability_parakeet_system_probes_directory(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # parakeet system models are directories. A mapped path that exists but is
    # a FILE is not a usable model dir.
    _use_tmp_data_home(monkeypatch, tmp_path)
    model = "parakeet-tdt-0.6b-v3"
    as_file = tmp_path / "not-a-dir"
    as_file.write_bytes(b"")

    assert (
        model_availability(
            "parakeet", model, system_paths={("parakeet", model): str(as_file)}
        ).state
        == "absent"
    )

    model_dir = tmp_path / "hash123-parakeet-tdt-0.6b-v3"
    model_dir.mkdir()
    got = model_availability(
        "parakeet", model, system_paths={("parakeet", model): str(model_dir)}
    )
    assert got == ModelAvailability(state="system", path=str(model_dir))


def test_availability_absolute_model_value_is_system(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # An off-catalog combo entry can BE an absolute path (kept verbatim by the
    # defaults loader). It is config-pinned by definition, so present reads as
    # "system" with itself as the transcribe path.
    _use_tmp_data_home(monkeypatch, tmp_path)
    weights = tmp_path / "abc123-ggml-house-style.bin"

    assert model_availability("whisper", str(weights)).state == "absent"

    weights.write_bytes(b"ggml")
    got = model_availability("whisper", str(weights))
    assert got == ModelAvailability(state="system", path=str(weights))


def test_availability_unknown_engine_and_empty_model_are_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _use_tmp_data_home(monkeypatch, tmp_path)

    assert model_availability("nemotron", "anything").state == "absent"
    assert model_availability("whisper", "").state == "absent"


def test_download_total_bytes_mirrors_voxtype_registry() -> None:
    # whisper sizes are voxtype's display-grade size_mb values, parakeet totals
    # are the exact per-file byte sums from its registry. Anything off-catalog
    # (custom paths included) has no known total. Progress goes indeterminate.
    assert download_total_bytes("whisper", "tiny") == 75 * 1024 * 1024
    assert download_total_bytes("whisper", "large-v3-turbo") == 1600 * 1024 * 1024
    assert download_total_bytes("parakeet", "parakeet-tdt-0.6b-v3") == 2_740_206_538
    assert download_total_bytes("parakeet", "parakeet-unified-en-0.6b") == 2_698_924_076
    assert download_total_bytes("whisper", "large-v2") is None
    assert download_total_bytes("parakeet", "/srv/models/custom") is None
    assert download_total_bytes("nemotron", "anything") is None


def test_download_progress_percent_is_clamped_and_total_aware() -> None:
    # The whisper totals are approximations, so the math never claims 100%.
    # Completion comes from the process exit status, not from byte counting.
    assert DownloadProgress(done_bytes=0, total_bytes=1000).percent == 0
    assert DownloadProgress(done_bytes=500, total_bytes=1000).percent == 50
    assert DownloadProgress(done_bytes=1000, total_bytes=1000).percent == 99
    assert DownloadProgress(done_bytes=2000, total_bytes=1000).percent == 99
    assert DownloadProgress(done_bytes=500, total_bytes=None).percent is None
    assert DownloadProgress(done_bytes=500, total_bytes=0).percent is None


# growing fake: write the ggml file in two visible steps so a poller sampling
# between them observes the artifact growing, then exit 0.
_GROWING_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
head -c 1000 /dev/zero > "$dir/ggml-$model.bin"
sleep 0.3
head -c 5000 /dev/zero > "$dir/ggml-$model.bin"
sleep 0.3
exit 0
"""


def test_download_reports_growing_progress_while_running(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The downloader writes straight into the final artifact (voxtype hands
    # curl -o the destination path), so polling its size is real progress.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _GROWING_FAKE)

    seen: list[DownloadProgress] = []
    result = download_model(
        "whisper",
        "tiny",
        voxtype_bin=fake,
        on_progress=seen.append,
        progress_interval=0.05,
    )

    assert result.ok is True
    assert len(seen) >= 2
    # Byte counts observed while running, growing monotonically to the final
    # size, every sample carrying the registry total for the percent math.
    assert [p.done_bytes for p in seen] == sorted(p.done_bytes for p in seen)
    assert seen[-1].done_bytes == 5000
    assert all(p.total_bytes == 75 * 1024 * 1024 for p in seen)


def test_download_progress_stops_with_the_process(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # No progress callback may fire after download_model returns: the app
    # marshals its completion right after, and a straggler would overwrite the
    # final ready/failed caption with a stale "downloading…".
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _WHISPER_FAKE)

    seen: list[DownloadProgress] = []
    download_model(
        "whisper",
        "tiny",
        voxtype_bin=fake,
        on_progress=seen.append,
        progress_interval=0.05,
    )
    count = len(seen)
    time.sleep(0.3)

    assert len(seen) == count


def test_model_present_is_the_boolean_view_of_availability(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # model_present stays as the presence-agnostic boolean so download-flip
    # tests and callers that only care about "is there anything" keep working.
    _use_tmp_data_home(monkeypatch, tmp_path)

    assert model_present("whisper", "tiny") is False

    root = Path(models_dir())
    root.mkdir(parents=True)
    (root / "ggml-tiny.bin").write_bytes(b"ggml")

    assert model_present("whisper", "tiny") is True


# on stdout: a progress line, then the ggml file run_setup looks for.
_ECHO_FAKE = """\
#!/usr/bin/env bash
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "downloading ggml-$model.bin (75 MB)"
echo "fetch: connecting to huggingface.co" >&2
dir="$XDG_DATA_HOME/voxtype/models"
mkdir -p "$dir"
: > "$dir/ggml-$model.bin"
exit 0
"""


def test_download_echoes_argv_and_output_to_app_stdout(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A download run from a terminal must surface the raw voxtype call so a
    # stalled or failed fetch isn't opaque: argv, returncode, and the full
    # captured stdout AND stderr all land on the app's own stdout.
    _use_tmp_data_home(monkeypatch, tmp_path)
    fake = _write_fake(tmp_path, "voxtype", _ECHO_FAKE)

    result = download_model("whisper", "tiny", voxtype_bin=fake)

    out = capsys.readouterr().out
    assert "[voxtype download]" in out
    # The exact argv is echoed, binary included.
    assert fake in out
    assert "setup" in out
    assert "--download" in out
    assert "returncode: 0" in out
    # Full stdout reaches the terminal.
    assert "downloading ggml-tiny.bin (75 MB)" in out
    # stderr must not be swallowed.
    assert "fetch: connecting to huggingface.co" in out
    # The echo is purely additive: the parsed result is unchanged.
    assert result.ok is True
    assert result.returncode == 0
