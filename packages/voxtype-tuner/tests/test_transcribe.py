"""Tests for the subprocess transcribe runner.

These exercise the real code path: a tiny shell script stands in for the
voxtype binary and emits a realistic preamble followed by the transcript line,
so the preamble-stripping logic is tested against actual subprocess output
rather than a monkeypatched parser.
"""

import os
import textwrap
import threading
import time
import tomllib
from dataclasses import replace
from pathlib import Path

import pytest
from voxtype_tuner.params import TranscribeParams, build_argv
from voxtype_tuner.transcribe import (
    CancelHandle,
    TranscribeResult,
    _recover_transcript,
    transcribe,
)

# Real captured leak: voxtype's local-whisper mode logs via tracing-subscriber
# (an ANSI-dim RFC3339 timestamp, an ANSI-green level word, then the message)
# and prints the actual transcript as the trailing un-prefixed line. The
# "Transcription completed …" log even carries a TRUNCATED quoted preview
# ("…count…") that must NOT be mistaken for the transcript. ESC codes are kept
# verbatim so the recovery is tested against reality, not an idealised capture.
_ESC = "\x1b"


def _log(ts: str, msg: str) -> str:
    return f"{_ESC}[2m{ts}{_ESC}[0m  {_ESC}[32m INFO{_ESC}[0m {msg}"


TRACING_LOG_LEAK = (
    "\n".join(
        [
            _log(
                "2026-07-03T11:35:02.313489Z", "Using local whisper transcription mode"
            ),
            _log(
                "2026-07-03T11:35:02.314169Z",
                'Loading whisper model from "/home/kenji/.local/share/voxtype/models/ggml-tiny.bin"',
            ),
            _log("2026-07-03T11:35:03.141689Z", "Model loaded in 0.83s"),
            _log(
                "2026-07-03T11:35:03.227656Z",
                'Transcription completed in 0.09s: "And so my fellow Americans ask not what your count..."',
            ),
            "And so my fellow Americans ask not what your country can do for you, "
            "ask what you can do for your country.",
        ]
    )
    + "\n"
)

CLEAN_TRANSCRIPT = (
    "And so my fellow Americans ask not what your country can do for you, "
    "ask what you can do for your country."
)

# Verified real voxtype stdout shape (E2E, whisper engine): tracing/preamble
# lines, then the transcript as the final meaningful line. The garbled wording
# is the actual transcription of an espeak "quick brown fox" clip, kept
# verbatim so the fixture matches reality rather than an idealized transcript.
PREAMBLE_SAMPLE = textwrap.dedent(
    """\
    Loading audio file: /tmp/s1.wav
    Audio format: 16000 Hz, 1 channel(s), 16-bit
    Resampling from 44100 Hz to 16000 Hz...
    Processing 1 audio chunk(s)...
    VAD: 2 speech segments, 3.20s of 4.00s speech
    The quick roundfire jump over the lazy dog.
    """
)


def _write_stub(tmp_path: Path, name: str, body: str) -> str:
    script = tmp_path / name
    script.write_text("#!/usr/bin/env bash\n" + body)
    script.chmod(0o755)
    return str(script)


def _params() -> TranscribeParams:
    return TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="hello",
        vad=True,
        vad_threshold=0.4,
        max_duration=60,
    )


def test_transcribe_strips_preamble_to_recover_transcript(tmp_path: Path) -> None:
    stub = _write_stub(
        tmp_path,
        "voxtype",
        "cat <<'EOF'\n" + PREAMBLE_SAMPLE + "EOF\n",
    )
    p = _params()
    result = transcribe("/tmp/s1.wav", p, voxtype_bin=stub)

    assert result.text == "The quick roundfire jump over the lazy dog."
    assert result.returncode == 0
    assert result.error is None
    assert result.argv == build_argv(p, "/tmp/s1.wav", voxtype_bin=stub)
    # raw stdout keeps the preamble untouched for debugging in the UI.
    assert "Loading audio file:" in result.raw_stdout
    assert "VAD:" in result.raw_stdout
    assert result.duration_s >= 0.0


def test_transcribe_multiline_transcript_joins_lines(tmp_path: Path) -> None:
    body = textwrap.dedent(
        """\
        Loading audio file: /tmp/s1.wav
        Processing 1 audio chunk(s)...
        [00:00:00.000 --> 00:00:02.000]  First line.
        [00:00:02.000 --> 00:00:04.000]  Second line.
        """
    )
    stub = _write_stub(tmp_path, "voxtype", "cat <<'EOF'\n" + body + "EOF\n")
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub)
    assert result.text == "First line. Second line."


def test_recover_transcript_drops_tracing_subscriber_logs() -> None:
    # The captured real leak: ANSI-coloured tracing-subscriber INFO lines must
    # be stripped whole, leaving ONLY the trailing plain transcript. The quoted
    # "…count…" preview inside the completed-log line is truncated and must not
    # be mistaken for the transcript.
    got = _recover_transcript(TRACING_LOG_LEAK)
    assert got == CLEAN_TRANSCRIPT
    assert "INFO" not in got
    assert "2026-07-03T" not in got
    assert "\x1b" not in got
    assert "count..." not in got  # the truncated log preview, never extracted


def test_transcribe_strips_tracing_logs_via_subprocess(tmp_path: Path) -> None:
    # Same leak through the real subprocess path: a fake voxtype prints the exact
    # ANSI capture, and only the clean transcript reaches result.text.
    stub = _write_stub(
        tmp_path, "voxtype", "cat <<'EOF'\n" + TRACING_LOG_LEAK + "EOF\n"
    )
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub)
    assert result.text == CLEAN_TRANSCRIPT
    # The raw echo path keeps everything for terminal debugging, untouched.
    assert "INFO" in result.raw_stdout


def test_transcribe_drops_noise_lines_around_timestamped_segments(
    tmp_path: Path,
) -> None:
    # Realistic timestamped run (jfk.wav-style): the preamble carries an extra
    # "Detected language:" note that no prefix in the plain-mode list covers.
    # The timestamped segments alone are the transcript, so that note (and all
    # other tracing) must be dropped, not bled into result.text.
    body = textwrap.dedent(
        """\
        Loading audio file: /tmp/s1.wav
        Audio format: 16000 Hz, 1 channel(s), 16-bit
        Resampling from 44100 Hz to 16000 Hz...
        Processing 2 audio chunk(s)...
        VAD: 3 speech segments, 5.10s of 6.00s speech
        Detected language: en (p = 0.98)
        [00:00:00.000 --> 00:00:05.000]  And so my fellow Americans,
        [00:00:05.000 --> 00:00:11.000]  ask not what your country can do for you.
        """
    )
    stub = _write_stub(tmp_path, "voxtype", "cat <<'EOF'\n" + body + "EOF\n")
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub)

    assert result.text == (
        "And so my fellow Americans, ask not what your country can do for you."
    )
    assert "Detected language" not in result.text
    assert "Loading audio file" not in result.text
    assert "VAD" not in result.text


def test_transcribe_captures_wall_clock_duration(tmp_path: Path) -> None:
    # duration_s is measured around the subprocess call and drives the UI's
    # "Transcribed in …" label, so it must reflect real elapsed wall-clock, not
    # voxtype's own (stripped) timing log line.
    stub = _write_stub(tmp_path, "voxtype", "sleep 0.2\necho done\n")
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub)
    assert result.duration_s >= 0.2
    assert result.duration_s < 5.0  # sanity: not wildly off


def test_transcribe_nonzero_exit_sets_error_without_raising(tmp_path: Path) -> None:
    stub = _write_stub(
        tmp_path,
        "voxtype",
        "echo 'error: model not found' >&2\nexit 1\n",
    )
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub)

    assert result.returncode == 1
    assert result.error is not None
    assert result.text == ""


def test_transcribe_missing_binary_reports_oserror(tmp_path: Path) -> None:
    missing = str(tmp_path / "does-not-exist")
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=missing)

    assert result.error is not None
    assert result.text == ""
    assert result.returncode != 0


def test_transcribe_timeout_uses_sentinel_returncode(tmp_path: Path) -> None:
    stub = _write_stub(tmp_path, "voxtype", "sleep 5\n")
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub, timeout=0.2)

    assert result.returncode == -1
    assert result.error is not None
    assert "timeout" in result.error.lower()
    assert result.text == ""


# parakeet fake: dump the -c config file voxtype was handed to $CONFIG_DUMP so
# the test can prove it EXISTED and held the right TOML at invocation time, then
# print a transcript. Reads the config with `cp`, which fails loudly if the file
# is missing, exactly the ENOENT the old --model path produced.
_PARAKEET_DUMP_FAKE = """\
cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) cfg="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$cfg" "$CONFIG_DUMP"
echo "the quick brown fox"
"""


def _parakeet_params(model: str) -> TranscribeParams:
    return TranscribeParams(
        engine="parakeet",
        model=model,
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )


def test_transcribe_parakeet_writes_config_and_cleans_up(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # parakeet has no --model: selection lives in a generated [parakeet] config
    # passed with -c. The config must exist and hold the right TOML while voxtype
    # runs, and be removed once transcribe returns.
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    result = transcribe(
        "/tmp/s1.wav", _parakeet_params("parakeet-tdt-0.6b-v3"), voxtype_bin=stub
    )

    assert result.returncode == 0
    assert result.text == "the quick brown fox"
    assert "--model" not in result.argv
    assert "-c" in result.argv

    # The config existed at invocation time (the stub cp'd it) and held the
    # generated TOML.
    assert dump.exists()
    cfg = tomllib.loads(dump.read_text())
    assert cfg["engine"] == "parakeet"
    assert cfg["parakeet"]["model"] == "parakeet-tdt-0.6b-v3"

    # ...and the temp config the argv pointed at is gone afterwards.
    cfg_path = result.argv[result.argv.index("-c") + 1]
    assert not Path(cfg_path).exists()


def test_transcribe_parakeet_unified_config_is_streaming(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The unified variant needs the streaming profile in its generated config.
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    transcribe(
        "/tmp/s1.wav", _parakeet_params("parakeet-unified-en-0.6b"), voxtype_bin=stub
    )

    cfg = tomllib.loads(dump.read_text())
    assert cfg["parakeet"]["streaming"] is True
    assert cfg["parakeet"]["streaming_chunk_secs"] == 0.56


def test_transcribe_parakeet_cleans_config_even_on_failure(tmp_path: Path) -> None:
    # never-raises + no leak: a nonzero voxtype exit still removes the temp
    # config, and the failure is folded into result.error.
    stub = _write_stub(tmp_path, "voxtype", "echo 'boom' >&2\nexit 1\n")

    result = transcribe(
        "/tmp/s1.wav", _parakeet_params("parakeet-tdt-0.6b-v3"), voxtype_bin=stub
    )

    assert result.returncode == 1
    assert result.error is not None
    cfg_path = result.argv[result.argv.index("-c") + 1]
    assert not Path(cfg_path).exists()


def test_transcribe_whisper_model_path_goes_through_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A system-provisioned whisper model is an absolute store path. The
    # top-level --model flag validates names against the bundled catalog and
    # silently drops a path (falling back to the config default), so the path
    # must travel in a generated [whisper] config passed with -c, the one
    # ungated route (resolve_model_path: is_absolute && exists).
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    result = transcribe(
        "/tmp/s1.wav",
        _params(),
        voxtype_bin=stub,
        model_path="/nix/store/abc-ggml-base.en.bin",
    )

    assert result.returncode == 0
    assert "--model" not in result.argv
    assert "-c" in result.argv

    cfg = tomllib.loads(dump.read_text())
    assert cfg["engine"] == "whisper"
    assert cfg["whisper"]["model"] == "/nix/store/abc-ggml-base.en.bin"

    # temp config removed after the run, like the parakeet route.
    cfg_path = result.argv[result.argv.index("-c") + 1]
    assert not Path(cfg_path).exists()


def test_transcribe_whisper_absolute_model_value_routes_through_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # An off-catalog combo entry can BE the absolute path. Passing it to
    # --model would be silently ignored, so transcribe must reroute it through
    # the config even without an explicit model_path.
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    p = replace(_params(), model="/nix/store/abc-ggml-house.bin")
    result = transcribe("/tmp/s1.wav", p, voxtype_bin=stub)

    assert "--model" not in result.argv
    cfg = tomllib.loads(dump.read_text())
    assert cfg["whisper"]["model"] == "/nix/store/abc-ggml-house.bin"


def test_transcribe_whisper_name_model_keeps_flag_route(tmp_path: Path) -> None:
    # Name-based whisper selection stays on the plain --model flag: no config
    # file is generated, nothing to clean up.
    stub = _write_stub(tmp_path, "voxtype", "echo ok\n")

    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub)

    assert "-c" not in result.argv
    assert result.argv[result.argv.index("--model") + 1] == "base.en"


def test_transcribe_parakeet_model_path_lands_in_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # System parakeet: catalog name selected, bytes at a store DIR. The config
    # model value must be the dir while the streaming profile still keys on
    # the NAME (the unified loader requirement is invisible from the path).
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    result = transcribe(
        "/tmp/s1.wav",
        _parakeet_params("parakeet-unified-en-0.6b"),
        voxtype_bin=stub,
        model_path="/nix/store/abc-parakeet-unified-en-0.6b",
    )

    assert result.returncode == 0
    cfg = tomllib.loads(dump.read_text())
    assert cfg["parakeet"]["model"] == "/nix/store/abc-parakeet-unified-en-0.6b"
    assert cfg["parakeet"]["streaming"] is True


def _nemotron_params() -> TranscribeParams:
    # The tuner has no nemotron model catalog (model=""). Its language control is
    # disabled for nemotron, so the serialized value is irrelevant here.
    return TranscribeParams(
        engine="nemotron",
        model="",
        language="auto",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )


def test_transcribe_nemotron_pins_model_path_in_config(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Nemotron is mandatory-config like parakeet: the model must reach voxtype in
    # a generated [nemotron] section (its store DIR pinned as the model value),
    # with --model dropped and the config cleaned up after the run.
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    result = transcribe(
        "/tmp/s1.wav",
        _nemotron_params(),
        voxtype_bin=stub,
        model_path="/nix/store/abc-nemotron-3.5-asr-streaming-0.6b",
    )

    assert result.returncode == 0
    assert "--model" not in result.argv
    assert "-c" in result.argv

    cfg = tomllib.loads(dump.read_text())
    assert cfg["engine"] == "nemotron"
    assert cfg["nemotron"]["model"] == "/nix/store/abc-nemotron-3.5-asr-streaming-0.6b"
    assert cfg["nemotron"]["target_lang"] == "auto"
    assert cfg["nemotron"]["streaming"] is False

    cfg_path = result.argv[result.argv.index("-c") + 1]
    assert not Path(cfg_path).exists()


def test_transcribe_nemotron_maps_language_to_target_lang(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The picker's single-select language reaches the daemon as nemotron's own
    # target_lang locale (de → de-DE), the whisper --language flag being ignored
    # by this engine. This is the batch path of the branch's headline feature.
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    result = transcribe(
        "/tmp/s1.wav",
        replace(_nemotron_params(), language="de"),
        voxtype_bin=stub,
        model_path="/nix/store/abc-nemotron-3.5-asr-streaming-0.6b",
    )

    assert result.returncode == 0
    cfg = tomllib.loads(dump.read_text())
    assert cfg["nemotron"]["target_lang"] == "de-DE"


def test_transcribe_nemotron_without_model_path_falls_back_to_registry_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # No provisioned path (bare checkout, no env): the config still holds a
    # resolvable registry NAME rather than a nonsense `model = "None"`, so voxtype
    # emits its own "model not found" rather than choking on the config.
    dump = tmp_path / "seen-config.toml"
    monkeypatch.setenv("CONFIG_DUMP", str(dump))
    stub = _write_stub(tmp_path, "voxtype", _PARAKEET_DUMP_FAKE)

    result = transcribe("/tmp/s1.wav", _nemotron_params(), voxtype_bin=stub)

    cfg = tomllib.loads(dump.read_text())
    assert cfg["nemotron"]["model"] == "nemotron-3.5-asr-streaming-0.6b"
    assert "None" not in cfg["nemotron"]["model"]
    assert result.returncode == 0


def test_transcribe_missing_binary_echoes_argv_and_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # A failed LAUNCH (ENOENT) must not be the one outcome that prints nothing to
    # a terminal-run app: the exact argv AND the OSError reach the app's own
    # stdout, exactly like a successful run. The original bare `voxtype-nemotron`
    # ENOENT was silent for precisely this reason.
    missing = str(tmp_path / "does-not-exist")
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=missing)

    out = capsys.readouterr().out
    assert "[voxtype transcribe]" in out
    assert missing in out
    assert "No such file or directory" in out
    assert result.error is not None
    assert result.text == ""


def test_transcribe_echoes_argv_and_output_to_app_stdout(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Running the app from a terminal must surface the raw voxtype call so
    # failures aren't opaque: the exact argv, the returncode, and the full
    # captured stdout AND stderr all land on the app's own stdout.
    stub = _write_stub(
        tmp_path,
        "voxtype",
        "cat <<'EOF'\n" + PREAMBLE_SAMPLE + "EOF\n"
        "echo 'whisper_init: loading model from disk' >&2\n",
    )
    p = _params()
    result = transcribe("/tmp/s1.wav", p, voxtype_bin=stub)

    out = capsys.readouterr().out
    assert "[voxtype transcribe]" in out
    # The exact argv (starting with the resolved binary) is echoed verbatim.
    assert stub in out
    assert "returncode: 0" in out
    # Full stdout reaches the terminal, preamble included (not just the
    # stripped transcript the UI shows).
    assert "Loading audio file:" in out
    assert "The quick roundfire jump over the lazy dog." in out
    # stderr must not be swallowed.
    assert "whisper_init: loading model from disk" in out
    # The echo is purely additive: the parsed result is unchanged.
    assert result.text == "The quick roundfire jump over the lazy dog."
    assert result.returncode == 0


def _wait_for_file(path: Path, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and path.read_text().strip():
            return
        time.sleep(0.02)
    msg = f"{path} never appeared"
    raise AssertionError(msg)


def _pid_gone(pid: int, timeout: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


def _run_transcribe_in_thread(
    stub: str, cancel: CancelHandle, timeout: float = 30.0
) -> tuple[threading.Thread, list[TranscribeResult]]:
    results: list[TranscribeResult] = []

    def work() -> None:
        results.append(
            transcribe(
                "/tmp/s1.wav",
                _params(),
                voxtype_bin=stub,
                timeout=timeout,
                cancel=cancel,
            )
        )

    thread = threading.Thread(target=work, daemon=True)
    thread.start()
    return thread, results


def test_cancel_terminates_the_subprocess_and_reports_cancelled(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The Stop action: a long-running voxtype must actually die (no orphan
    # keeps holding the audio file / burning CPU) and the worker must see a
    # CANCELLED result, never a fake success or failure.
    pid_file = tmp_path / "stub.pid"
    monkeypatch.setenv("STUB_PID_FILE", str(pid_file))
    stub = _write_stub(tmp_path, "voxtype", 'echo $$ > "$STUB_PID_FILE"\nsleep 30\n')

    cancel = CancelHandle()
    thread, results = _run_transcribe_in_thread(stub, cancel)
    _wait_for_file(pid_file)

    cancel.cancel()
    thread.join(10.0)

    assert not thread.is_alive(), "worker never observed the kill"
    assert results[0].cancelled is True
    assert results[0].error == "cancelled"
    assert results[0].text == ""
    assert _pid_gone(int(pid_file.read_text())), "voxtype survived the cancel"


def test_cancel_escalates_to_kill_when_term_is_ignored(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A wedged voxtype that ignores SIGTERM must still die: terminate→kill
    # escalation, bounded by the handle's grace period.
    pid_file = tmp_path / "stub.pid"
    monkeypatch.setenv("STUB_PID_FILE", str(pid_file))
    stub = _write_stub(
        tmp_path,
        "voxtype",
        'trap "" TERM\necho $$ > "$STUB_PID_FILE"\nwhile true; do sleep 0.1; done\n',
    )

    cancel = CancelHandle(kill_grace_s=0.3)
    thread, results = _run_transcribe_in_thread(stub, cancel)
    _wait_for_file(pid_file)

    cancel.cancel()
    thread.join(10.0)

    assert not thread.is_alive(), "escalation never fired"
    assert results[0].cancelled is True
    assert _pid_gone(int(pid_file.read_text()))


def test_cancel_before_the_subprocess_starts_kills_it_at_attach(
    tmp_path: Path,
) -> None:
    # A Stop click racing the worker's spawn: the handle is already cancelled
    # when the subprocess attaches, so it dies immediately instead of running
    # to completion behind a "cancelled" UI.
    stub = _write_stub(tmp_path, "voxtype", "sleep 30\n")

    cancel = CancelHandle()
    cancel.cancel()
    result = transcribe("/tmp/s1.wav", _params(), voxtype_bin=stub, cancel=cancel)

    assert result.cancelled is True
    assert result.error == "cancelled"


def test_uncancelled_run_reports_cancelled_false(tmp_path: Path) -> None:
    stub = _write_stub(tmp_path, "voxtype", "echo hi\n")
    result = transcribe(
        "/tmp/s1.wav", _params(), voxtype_bin=stub, cancel=CancelHandle()
    )
    assert result.cancelled is False
    assert result.text == "hi"


@pytest.mark.slow
def test_nemotron_end_to_end_real_binary_returns_transcript() -> None:
    # The done-bar: drive an ACTUAL nemotron transcribe through the tuner's own
    # build_argv/transcribe path and prove a non-empty transcript comes back.
    # Skipped unless the real fork voxtype, the provisioned model dir, and a
    # speech WAV are all supplied, the same three the packaged wrapper sets, so
    # this is runnable straight against a built tuner's environment.
    voxtype_bin = os.environ.get("VOXTYPE_BIN")
    model_path = os.environ.get("VOXTYPE_NEMOTRON_MODEL")
    wav = os.environ.get("VOXTYPE_TUNER_SAMPLE_WAV")
    if not (voxtype_bin and model_path and wav):
        pytest.skip(
            "set VOXTYPE_BIN, VOXTYPE_NEMOTRON_MODEL and VOXTYPE_TUNER_SAMPLE_WAV "
            "to real paths to exercise the real nemotron transcribe"
        )

    # Loading the ~2.6 GB fp32 export is slow. Give the launch generous room.
    result = transcribe(
        wav,
        _nemotron_params(),
        voxtype_bin=voxtype_bin,
        model_path=model_path,
        timeout=300.0,
    )

    assert result.error is None, result.raw_stdout or result.error
    assert result.text.strip(), "nemotron returned an empty transcript"


@pytest.mark.slow
def test_nemotron_end_to_end_real_binary_accepts_selected_target_lang() -> None:
    # The language done-bar: drive the tuner's own transcribe path with a
    # NON-auto picker selection ("es" → target_lang "es-ES") and prove the real
    # fork voxtype ACCEPTS the mapped locale and runs. An invalid locale would
    # fail load with "Unknown target language". es-ES is the curated locale that
    # still yields text on the English sample, whereas de-DE/fr-FR load fine but the
    # German/French heads emit nothing on English audio, so this one asserts on
    # output. Same three env vars the packaged wrapper sets.
    voxtype_bin = os.environ.get("VOXTYPE_BIN")
    model_path = os.environ.get("VOXTYPE_NEMOTRON_MODEL")
    wav = os.environ.get("VOXTYPE_TUNER_SAMPLE_WAV")
    if not (voxtype_bin and model_path and wav):
        pytest.skip(
            "set VOXTYPE_BIN, VOXTYPE_NEMOTRON_MODEL and VOXTYPE_TUNER_SAMPLE_WAV "
            "to real paths to exercise the real nemotron target_lang mapping"
        )

    result = transcribe(
        wav,
        replace(_nemotron_params(), language="es"),
        voxtype_bin=voxtype_bin,
        model_path=model_path,
        timeout=300.0,
    )

    # error is None means voxtype accepted the [nemotron] target_lang the tuner
    # generated (an invalid locale exits non-zero at load). The unit test
    # test_transcribe_nemotron_maps_language_to_target_lang proves that config
    # carried "es-ES". The transcribe path routes the model through a -c config,
    # cleaned up on return.
    assert result.error is None, result.raw_stdout or result.error
    assert "-c" in result.argv
    assert result.text.strip(), "nemotron returned an empty transcript for es-ES"
