"""Tests for the config serializer and the apply/revert orchestration.

Pure logic plus two thin filesystem/subprocess seams. The serializer is the
part that must be provably faithful: voxtype layers a user config over its
BUILT-IN defaults (never over the system file), so the override the tuner writes
has to be COMPLETE. Every baseline key the daemon should keep must survive.
The round-trip tests assert exactly that, key by key, and the apply tests drive
a fake ``systemctl`` so nothing here ever touches the real daemon.
"""

from __future__ import annotations

import tomllib
from dataclasses import replace
from textwrap import dedent
from typing import TYPE_CHECKING, Any

import pytest
from voxtype_tuner import apply, defaults, params

if TYPE_CHECKING:
    from collections.abc import Mapping
    from pathlib import Path

    from voxtype_tuner.params import TranscribeParams

# The two baseline shapes the NixOS module generates, reused from the loader
# tests: a whisper system (store-path model, full safety-key set) and a
# streaming parakeet system.
_SYSTEM_WHISPER_TOML = """\
engine = "whisper"
state_file = "auto"

[audio]
device = "default"
max_duration_secs = 60
sample_rate = 16000

[hotkey]
enabled = false
key = "SCROLLLOCK"
modifiers = []

[osd]
enabled = false

[output]
fallback_to_clipboard = true
mode = "type"
pre_type_delay_ms = 0
type_delay_ms = 0

[output.notification]
on_recording_start = false
on_recording_stop = false
on_transcription = false

[status]
icon_theme = "emoji"

[vad]
backend = "energy"
enabled = true
min_speech_duration_ms = 100
threshold = 0.4

[whisper]
initial_prompt = "Voice input from a Spaces OS user dictating to the pi agent."
language = "auto"
model = "/nix/store/cp89s185x1ykj4fi5a5mn9nlbvz1vwnn-ggml-small.bin"
on_demand_loading = false
translate = false
"""

_SYSTEM_PARAKEET_TOML = """\
engine = "parakeet"
state_file = "auto"

[audio]
max_duration_secs = 60

[hotkey]
enabled = false

[osd]
enabled = false

[parakeet]
model = "parakeet-unified-en-0.6b"
streaming = true
streaming_chunk_secs = 0.56
streaming_left_context_secs = 5.6
streaming_right_context_secs = 0.56

[vad]
backend = "energy"
enabled = true
min_speech_duration_ms = 100
threshold = 0.4

[whisper]
language = "en"
model = "base.en"
on_demand_loading = false
translate = false
"""


# The nemotron-engine shape the module generates: [nemotron] carries the
# provisioned store-path model, target_lang and JUST the streaming boolean,
# never parakeet's mel-frame context profile.
_SYSTEM_NEMOTRON_TOML = """\
engine = "nemotron"
state_file = "auto"

[audio]
max_duration_secs = 60

[hotkey]
enabled = false

[nemotron]
model = "/nix/store/abc123-nemotron-3.5-asr-streaming-0.6b"
streaming = true
target_lang = "auto"

[osd]
enabled = false

[vad]
backend = "energy"
enabled = true
min_speech_duration_ms = 100
threshold = 0.4

[whisper]
language = "en"
model = "base.en"
on_demand_loading = false
translate = false
"""


def _parse(text: str) -> dict[str, Any]:
    return tomllib.loads(text)


def _seed(baseline_text: str) -> tuple[TranscribeParams, dict[str, Any]]:
    """Parse a baseline both as modeled params and as the raw preserved table."""
    raw = _parse(baseline_text)
    return defaults._params_from_toml(raw), raw


# --- TOML emitter round-trips -------------------------------------------------


def test_emitter_round_trips_the_whisper_baseline() -> None:
    raw = _parse(_SYSTEM_WHISPER_TOML)
    assert _parse(apply._dump_toml(raw)) == raw


def test_emitter_round_trips_the_parakeet_baseline() -> None:
    raw = _parse(_SYSTEM_PARAKEET_TOML)
    assert _parse(apply._dump_toml(raw)) == raw


def test_emitter_handles_arrays_tables_and_escapes() -> None:
    # A hand-edited config can carry shapes the module never emits: nested
    # tables, an array of tables, string arrays, quote/backslash/control chars.
    raw = _parse(
        dedent(
            """\
            engine = "whisper"
            title = "a \\"quoted\\" \\\\ path\\tend"
            ratio = 0.56
            count = 3
            flag = true
            codes = ["en", "de"]
            empty = []

            [osd]
            enabled = true

            [[osd.visual.layers]]
            type = "waveform"
            gain = 10.0

            [[osd.visual.layers]]
            type = "label"
            """
        )
    )
    assert _parse(apply._dump_toml(raw)) == raw


# --- serialize preserves every baseline key -----------------------------------


def _leaf_keys(table: Mapping[str, object], prefix: str = "") -> set[str]:
    keys: set[str] = set()
    for key, value in table.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict):
            keys |= _leaf_keys(value, prefix=f"{path}.")
        else:
            keys.add(path)
    return keys


def test_whisper_baseline_round_trips_every_key_when_unchanged() -> None:
    # The headline safety property: applying the baseline unchanged (as the UI
    # shows it at seed time, system model materialized so it reads "system")
    # must preserve EVERY baseline key verbatim (hotkey/osd/output safety flags
    # included) and re-reference the whisper store path.
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    store_path = raw["whisper"]["model"]
    # A system model serializes to its absolute store path. Pin it directly (the
    # store path does not exist in the sandbox, so resolve_model_value has its
    # own dedicated tests below).
    got = _parse(apply.serialize_config(p, raw, store_path))

    # Every baseline leaf key still present.
    assert _leaf_keys(raw) <= _leaf_keys(got)
    # The pinned safety flags survived verbatim.
    assert got["hotkey"]["enabled"] is False
    assert got["osd"]["enabled"] is False
    assert got["output"]["notification"]["on_transcription"] is False
    assert got["status"]["icon_theme"] == "emoji"
    assert got["audio"]["device"] == "default"
    assert got["whisper"]["translate"] is False
    assert got["whisper"]["on_demand_loading"] is False
    # The whisper model round-trips to the absolute store path, not the name.
    assert got["whisper"]["model"] == store_path
    assert got["engine"] == "whisper"
    assert got["vad"]["enabled"] is True


def test_parakeet_baseline_round_trips_every_key_when_unchanged() -> None:
    p, raw = _seed(_SYSTEM_PARAKEET_TOML)
    # parakeet model is a plain name (no store path in the module): serialize by
    # name.
    got = _parse(apply.serialize_config(p, raw, p.model))

    assert _leaf_keys(raw) <= _leaf_keys(got)
    assert got["engine"] == "parakeet"
    assert got["parakeet"]["model"] == "parakeet-unified-en-0.6b"
    assert got["parakeet"]["streaming"] is True
    # The blessed streaming context survived verbatim.
    assert got["parakeet"]["streaming_chunk_secs"] == 0.56
    assert got["parakeet"]["streaming_left_context_secs"] == 5.6
    assert got["parakeet"]["streaming_right_context_secs"] == 0.56
    # The upstream-merged [whisper] block is preserved even under parakeet.
    assert got["whisper"]["model"] == "base.en"
    assert got["hotkey"]["enabled"] is False


# --- modeled keys reflect the UI ----------------------------------------------


def test_edited_params_overlay_the_baseline() -> None:
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    edited = replace(
        p,
        model="base.en",
        language="en,de",
        initial_prompt="",
        vad=False,
        vad_threshold=0.6,
        max_duration=120,
    )
    got = _parse(apply.serialize_config(edited, raw, "base.en"))

    assert got["whisper"]["model"] == "base.en"
    # multi-language serializes as an ARRAY (voxtype's LanguageConfig), never a
    # comma string.
    assert got["whisper"]["language"] == ["en", "de"]
    # an emptied prompt drops the key rather than writing "".
    assert "initial_prompt" not in got["whisper"]
    assert got["vad"]["enabled"] is False
    assert got["vad"]["threshold"] == 0.6
    assert got["audio"]["max_duration_secs"] == 120
    # unmodeled vad keys preserved even as enabled/threshold change.
    assert got["vad"]["backend"] == "energy"


def test_single_language_and_auto_serialize_as_bare_strings() -> None:
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    assert (
        _parse(apply.serialize_config(replace(p, language="en"), raw, "x"))["whisper"][
            "language"
        ]
        == "en"
    )
    assert (
        _parse(apply.serialize_config(replace(p, language="auto"), raw, "x"))[
            "whisper"
        ]["language"]
        == "auto"
    )


def test_switching_whisper_to_parakeet_creates_table_preserves_whisper() -> None:
    # From a whisper baseline: selecting parakeet must add a [parakeet] table
    # with the model + streaming while the [whisper] block (unmodeled model)
    # stays verbatim.
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    edited = replace(
        p, engine="parakeet", model="parakeet-unified-en-0.6b", streaming=True
    )
    got = _parse(apply.serialize_config(edited, raw, "parakeet-unified-en-0.6b"))

    assert got["engine"] == "parakeet"
    assert got["parakeet"]["model"] == "parakeet-unified-en-0.6b"
    assert got["parakeet"]["streaming"] is True
    # blessed context injected even though the whisper baseline had none.
    assert got["parakeet"]["streaming_chunk_secs"] == 0.56
    assert got["parakeet"]["streaming_left_context_secs"] == 5.6
    # the whisper store-path model is preserved untouched under parakeet.
    assert got["whisper"]["model"].endswith("ggml-small.bin")


def test_streaming_off_writes_false_and_keeps_context_verbatim() -> None:
    p, raw = _seed(_SYSTEM_PARAKEET_TOML)
    got = _parse(apply.serialize_config(replace(p, streaming=False), raw, p.model))

    assert got["parakeet"]["streaming"] is False
    # context keys are preserved (harmless when streaming is off, and they
    # round-trip the baseline).
    assert got["parakeet"]["streaming_chunk_secs"] == 0.56


# --- nemotron: streaming write is JUST the boolean ----------------------------


def test_nemotron_baseline_writes_streaming_and_preserves_model() -> None:
    # The headline nemotron fact: Apply writes [nemotron].streaming and NOTHING
    # parakeet-shaped, while preserving the baseline's provisioned model +
    # target_lang and every other safety key verbatim.
    p, raw = _seed(_SYSTEM_NEMOTRON_TOML)
    assert p.engine == "nemotron"
    assert p.streaming is True
    got = _parse(apply.serialize_config(p, raw, params.DEFAULT_NEMOTRON_MODEL))

    assert _leaf_keys(raw) <= _leaf_keys(got)
    assert got["engine"] == "nemotron"
    assert got["nemotron"]["streaming"] is True
    assert (
        got["nemotron"]["model"] == "/nix/store/abc123-nemotron-3.5-asr-streaming-0.6b"
    )
    assert got["nemotron"]["target_lang"] == "auto"
    # Never parakeet's mel-frame context, never a [parakeet] table.
    assert "parakeet" not in got
    for key in (
        "streaming_chunk_secs",
        "streaming_left_context_secs",
        "streaming_right_context_secs",
    ):
        assert key not in got["nemotron"]
    assert got["hotkey"]["enabled"] is False
    assert got["whisper"]["model"] == "base.en"


def test_nemotron_streaming_off_writes_false_and_no_context() -> None:
    p, raw = _seed(_SYSTEM_NEMOTRON_TOML)
    got = _parse(
        apply.serialize_config(
            replace(p, streaming=False), raw, params.DEFAULT_NEMOTRON_MODEL
        )
    )

    assert got["nemotron"]["streaming"] is False
    assert "streaming_chunk_secs" not in got["nemotron"]


def test_switching_to_nemotron_creates_section_and_pins_model() -> None:
    # From a whisper baseline (no [nemotron] table): selecting nemotron must add
    # a [nemotron] table with the pinned model + streaming so voxtype does not
    # hard-fail on a missing section, and NEVER emit parakeet context.
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    edited = replace(p, engine="nemotron", model="", streaming=True)
    got = _parse(apply.serialize_config(edited, raw, "/nix/store/x-nemotron-3.5"))

    assert got["engine"] == "nemotron"
    assert got["nemotron"]["model"] == "/nix/store/x-nemotron-3.5"
    assert got["nemotron"]["streaming"] is True
    assert got["nemotron"]["target_lang"] == "auto"
    assert "parakeet" not in got
    assert "streaming_chunk_secs" not in got["nemotron"]
    # the whisper store-path model is preserved untouched under nemotron.
    assert got["whisper"]["model"].endswith("ggml-small.bin")


def test_nemotron_apply_writes_selected_target_lang_and_keeps_whisper_language() -> (
    None
):
    # Apply writes the PICKER's language as nemotron's own target_lang locale
    # (de → de-DE), replacing the baseline's "auto". The [whisper].language "en"
    # is preserved untouched. It belongs to a future whisper switch, and the
    # nemotron picker value must not clobber it.
    p, raw = _seed(_SYSTEM_NEMOTRON_TOML)
    assert p.language == "auto"  # seeded from [nemotron].target_lang, not whisper
    got = _parse(
        apply.serialize_config(
            replace(p, language="de"), raw, params.DEFAULT_NEMOTRON_MODEL
        )
    )

    assert got["nemotron"]["target_lang"] == "de-DE"
    assert got["whisper"]["language"] == "en"


def test_nemotron_target_lang_round_trips_seed_to_apply() -> None:
    # The honest round-trip: a [nemotron].target_lang = "de-DE" system config
    # seeds the picker to "de", and an untouched Apply writes "de-DE" straight
    # back. No drift, so the modified-dot and preview stay truthful.
    baseline = dedent(
        """\
        engine = "nemotron"

        [nemotron]
        model = "/nix/store/x-nemotron"
        target_lang = "de-DE"
        """
    )
    p, raw = _seed(baseline)
    assert p.language == "de"
    got = _parse(apply.serialize_config(p, raw, params.DEFAULT_NEMOTRON_MODEL))
    assert got["nemotron"]["target_lang"] == "de-DE"


def test_resolve_model_value_nemotron_uses_provisioned_path() -> None:
    got = apply.resolve_model_value(
        "nemotron", "", None, nemotron_model="/nix/store/x-nemotron"
    )
    assert got == "/nix/store/x-nemotron"


def test_resolve_model_value_nemotron_falls_back_to_default_name() -> None:
    got = apply.resolve_model_value("nemotron", "", None)
    assert got == params.DEFAULT_NEMOTRON_MODEL


def test_no_baseline_writes_only_modeled_keys() -> None:
    # No system config: nothing to preserve, so only the modeled keys are
    # written and the daemon fills the rest from its built-ins.
    p = defaults.BUILTIN_DEFAULTS
    got = _parse(apply.serialize_config(p, None, "tiny"))

    assert got["engine"] == "whisper"
    assert got["whisper"]["model"] == "tiny"
    assert got["vad"]["enabled"] is True
    assert got["audio"]["max_duration_secs"] == 60
    assert "hotkey" not in got  # nothing to preserve


def test_vad_enabled_written_explicitly_even_when_off() -> None:
    # fact 5: an explicit `enabled = false` is the only round-trippable way to
    # say VAD off, since the module OMITS [vad] when disabled.
    p = replace(defaults.BUILTIN_DEFAULTS, vad=False)
    got = _parse(apply.serialize_config(p, None, "tiny"))

    assert got["vad"]["enabled"] is False


def test_serialize_does_not_mutate_the_baseline() -> None:
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    before = _parse(_SYSTEM_WHISPER_TOML)
    apply.serialize_config(replace(p, engine="parakeet", model="x"), raw, "x")
    assert raw == before


# --- resolve_model_value ------------------------------------------------------


def test_resolve_model_value_prefers_system_store_path(tmp_path: Path) -> None:
    weights = tmp_path / "abc-ggml-small.bin"
    weights.write_bytes(b"ggml")
    got = apply.resolve_model_value(
        "whisper", "small", {("whisper", "small"): str(weights)}
    )
    assert got == str(weights)


def test_resolve_model_value_falls_back_to_name_when_absent(tmp_path: Path) -> None:
    # Mapped path whose bytes are gone -> not "system" -> write the name.
    got = apply.resolve_model_value(
        "whisper", "small", {("whisper", "small"): str(tmp_path / "gone.bin")}
    )
    assert got == "small"


# --- config_changes preview ---------------------------------------------------


def test_config_changes_lists_each_differing_param() -> None:
    eff = defaults.BUILTIN_DEFAULTS
    cur = replace(eff, model="small", vad=False, max_duration=120)
    changes = apply.config_changes(cur, eff)
    lines = [c.line() for c in changes]

    assert "Model: tiny → small" in lines
    assert "VAD: on → off" in lines
    assert "Max duration: 60s → 120s" in lines
    assert len(changes) == 3


def test_config_changes_empty_when_equal() -> None:
    assert (
        apply.config_changes(defaults.BUILTIN_DEFAULTS, defaults.BUILTIN_DEFAULTS) == []
    )


def test_config_changes_formats_streaming_and_language() -> None:
    eff = replace(defaults.BUILTIN_DEFAULTS, engine="parakeet", model="x")
    cur = replace(eff, streaming=True, language="en,de")
    lines = [c.line() for c in apply.config_changes(cur, eff)]

    assert "Streaming: off → on" in lines
    assert "Language: en → en,de" in lines


# --- [audio] device round-trip ------------------------------------------------


def test_device_written_to_the_audio_table() -> None:
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    got = _parse(apply.serialize_config(replace(p, device="Blue Yeti"), raw, "x"))
    assert got["audio"]["device"] == "Blue Yeti"
    # It lands beside, not on top of, the preserved [audio] keys.
    assert got["audio"]["max_duration_secs"] == 60
    assert got["audio"]["sample_rate"] == 16000


def test_device_round_trips_from_the_baseline_when_unchanged() -> None:
    # A system config pinning a specific input round-trips it: seeding reads
    # [audio].device into the params, and an unchanged Apply writes it back.
    raw = _parse(_SYSTEM_WHISPER_TOML.replace('device = "default"', 'device = "pulse"'))
    p = defaults._params_from_toml(raw)
    assert p.device == "pulse"
    got = _parse(apply.serialize_config(p, raw, raw["whisper"]["model"]))
    assert got["audio"]["device"] == "pulse"


def test_empty_device_normalizes_to_default_on_write() -> None:
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    got = _parse(apply.serialize_config(replace(p, device=""), raw, "x"))
    assert got["audio"]["device"] == "default"


def test_config_changes_lists_a_device_change() -> None:
    p, _ = _seed(_SYSTEM_WHISPER_TOML)  # seeded device: "default"
    changes = apply.config_changes(replace(p, device="Blue Yeti"), p)
    labels = {c.label: (c.old, c.new) for c in changes}
    assert labels["Device"] == ("system default", "Blue Yeti")


# --- write + restart seams ----------------------------------------------------


def _fake_systemctl(tmp_path: Path, *, exit_code: int, record: Path) -> str:
    """A fake `systemctl` that records its argv and exits with ``exit_code``."""
    script = tmp_path / "fake-systemctl"
    script.write_text(
        f'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > {record}\nexit {exit_code}\n'
    )
    script.chmod(0o755)
    return str(script)


def test_write_config_atomic_writes_full_file(tmp_path: Path) -> None:
    target = tmp_path / "nested" / "config.toml"
    apply.write_config_atomic(str(target), 'engine = "whisper"\n')
    assert target.read_text() == 'engine = "whisper"\n'
    # No temp files left behind.
    assert list(target.parent.glob(".config-*")) == []


def test_write_config_atomic_leaves_no_partial_on_failure(tmp_path: Path) -> None:
    # Injected write failure (a directory where the file should go): the atomic
    # write raises and leaves neither a partial target nor a temp file.
    target = tmp_path / "config.toml"
    target.mkdir()  # make the rename target a directory so os.replace fails
    with pytest.raises(OSError, match=r"[Ee]rrno"):
        apply.write_config_atomic(str(target), "x = 1\n")
    assert list(tmp_path.glob(".config-*")) == []


def test_restart_records_argv_and_reports_success(tmp_path: Path) -> None:
    record = tmp_path / "argv"
    systemctl = _fake_systemctl(tmp_path, exit_code=0, record=record)
    ok, reason = apply.restart_daemon(systemctl)
    assert ok is True
    assert reason == ""
    assert record.read_text().split() == ["--user", "restart", "voxtype"]


def test_restart_failure_is_surfaced(tmp_path: Path) -> None:
    systemctl = _fake_systemctl(tmp_path, exit_code=1, record=tmp_path / "argv")
    ok, reason = apply.restart_daemon(systemctl)
    assert ok is False
    assert reason  # a non-empty reason for the status bar


def test_restart_missing_binary_is_surfaced(tmp_path: Path) -> None:
    ok, reason = apply.restart_daemon(str(tmp_path / "no-such-systemctl"))
    assert ok is False
    assert reason


def test_apply_config_writes_and_restarts(tmp_path: Path) -> None:
    record = tmp_path / "argv"
    systemctl = _fake_systemctl(tmp_path, exit_code=0, record=record)
    config = tmp_path / "voxtype" / "config.toml"
    p, raw = _seed(_SYSTEM_WHISPER_TOML)

    outcome = apply.apply_config(p, raw, None, str(config), systemctl)

    assert outcome.ok is True
    assert outcome.kind == "applied"
    assert outcome.message == "applied, daemon restarted"
    # The file is a complete, parseable config with the safety flags intact.
    written = tomllib.loads(config.read_text())
    assert written["hotkey"]["enabled"] is False
    assert record.read_text().split() == ["--user", "restart", "voxtype"]


def test_apply_config_restart_failure_keeps_file_and_points_to_escape(
    tmp_path: Path,
) -> None:
    systemctl = _fake_systemctl(tmp_path, exit_code=1, record=tmp_path / "argv")
    config = tmp_path / "config.toml"
    p, raw = _seed(_SYSTEM_WHISPER_TOML)

    outcome = apply.apply_config(p, raw, None, str(config), systemctl)

    assert outcome.ok is False
    assert outcome.kind == "restart_failed"
    assert str(config) in outcome.message  # names the escape hatch
    assert config.exists()  # the written override is left in place


def test_apply_config_write_failure_never_restarts(tmp_path: Path) -> None:
    record = tmp_path / "argv"
    systemctl = _fake_systemctl(tmp_path, exit_code=0, record=record)
    target = tmp_path / "config.toml"
    target.mkdir()  # force the write to fail
    p, raw = _seed(_SYSTEM_WHISPER_TOML)

    outcome = apply.apply_config(p, raw, None, str(target), systemctl)

    assert outcome.ok is False
    assert outcome.kind == "write_failed"
    assert not record.exists()  # systemctl never ran


def test_revert_removes_file_and_restarts(tmp_path: Path) -> None:
    record = tmp_path / "argv"
    systemctl = _fake_systemctl(tmp_path, exit_code=0, record=record)
    config = tmp_path / "config.toml"
    config.write_text('engine = "whisper"\n')

    outcome = apply.revert_config(str(config), systemctl)

    assert outcome.ok is True
    assert outcome.kind == "reverted"
    assert not config.exists()
    assert record.read_text().split() == ["--user", "restart", "voxtype"]


def test_revert_missing_file_is_a_noop_success(tmp_path: Path) -> None:
    systemctl = _fake_systemctl(tmp_path, exit_code=0, record=tmp_path / "argv")
    outcome = apply.revert_config(str(tmp_path / "absent.toml"), systemctl)
    assert outcome.ok is True
    assert outcome.kind == "reverted"
