"""Tests for the system-defaults loader: file resolution, TOML parsing with
per-key fallbacks, catalog seeding, and the modified-vs-default diff.

Pure logic, no ``slint`` import. Every file-reading test writes its own TOML
under ``tmp_path`` and injects it through the ``environ`` parameter, so nothing
here touches ``/etc``, so the suite runs unchanged in the nix-build sandbox.
"""

from dataclasses import replace
from pathlib import Path
from textwrap import dedent

from voxtype_tuner import params
from voxtype_tuner.defaults import (
    BUILTIN_DEFAULTS,
    ENV_VAR,
    SeededControls,
    SystemDefaults,
    load_defaults,
    load_startup,
    model_catalog_for,
    modified_fields,
    seed_controls,
    user_config_path,
)
from voxtype_tuner.params import TranscribeParams
from voxtype_tuner.wiring import build_params, serialize_language

# Mirrors the file modules/nixos/voxtype.nix generates for the default
# (whisper) engine: upstream default.toml deep-merged with the module's
# engine/vad/hotkey/osd/output overrides. whisper.model is the fetchurl store
# path, not a catalog name (the quirk the loader must map back).
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

# The parakeet-engine shape: [parakeet] carries the model, [whisper] is the
# untouched upstream block (bare model name, no initial_prompt).
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


# The nemotron-engine shape: [nemotron] carries the provisioned store-path
# model, target_lang and JUST the streaming boolean (no context profile).
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


def _write(tmp_path: Path, text: str, name: str = "config.toml") -> Path:
    path = tmp_path / name
    path.write_text(dedent(text))
    return path


def _load(tmp_path: Path, text: str) -> SystemDefaults:
    return load_defaults(environ={ENV_VAR: str(_write(tmp_path, text))})


def test_env_override_wins_over_system_path(tmp_path: Path) -> None:
    override = _write(tmp_path, _SYSTEM_PARAKEET_TOML, name="override.toml")
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")

    got = load_defaults(environ={ENV_VAR: str(override)}, system_path=str(system))

    assert got.loaded is True
    assert got.params.engine == "parakeet"
    assert got.status == f"System defaults: {override}"


def test_env_override_pointing_at_missing_file_uses_builtins(tmp_path: Path) -> None:
    # An explicit override is authoritative: a typo'd path must be visible as
    # "not found", never silently masked by falling through to /etc.
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")

    got = load_defaults(
        environ={ENV_VAR: str(tmp_path / "nope.toml")}, system_path=str(system)
    )

    assert got.loaded is False
    assert got.params == BUILTIN_DEFAULTS
    assert got.status == "System defaults: not found, using built-ins"


def test_system_path_used_when_no_override(tmp_path: Path) -> None:
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")

    got = load_defaults(environ={}, system_path=str(system))

    assert got.loaded is True
    assert got.params.model == "small"
    assert got.status == f"System defaults: {system}"


def test_missing_everything_falls_back_to_builtins(tmp_path: Path) -> None:
    got = load_defaults(environ={}, system_path=str(tmp_path / "absent.toml"))

    assert got.loaded is False
    assert got.params == BUILTIN_DEFAULTS
    assert got.status == "System defaults: not found, using built-ins"


def test_malformed_file_falls_back_to_builtins_wholesale(tmp_path: Path) -> None:
    # tomllib yields nothing partial from a broken file, so the only honest
    # fallback is the whole built-in set, flagged distinctly from "not found".
    got = _load(tmp_path, 'engine = "whisper\n[vad')

    assert got.loaded is False
    assert got.params == BUILTIN_DEFAULTS
    assert got.status == "System defaults: unreadable, using built-ins"


def test_unreadable_path_falls_back_to_builtins(tmp_path: Path) -> None:
    # A directory (or any OSError on open) is "unreadable", same as bad TOML.
    got = load_defaults(environ={ENV_VAR: str(tmp_path)})

    assert got.loaded is False
    assert got.params == BUILTIN_DEFAULTS
    assert got.status == "System defaults: unreadable, using built-ins"


def test_full_system_file_seeds_all_params(tmp_path: Path) -> None:
    got = _load(tmp_path, _SYSTEM_WHISPER_TOML)

    assert got.loaded is True
    assert got.params == TranscribeParams(
        engine="whisper",
        # store path mapped back to the catalog name via ggml-<name>.bin
        model="small",
        language="auto",
        initial_prompt="Voice input from a Spaces OS user dictating to the pi agent.",
        vad=True,
        vad_threshold=0.4,
        max_duration=60,
    )


def test_device_seeded_from_audio_table(tmp_path: Path) -> None:
    got = _load(
        tmp_path, _SYSTEM_WHISPER_TOML.replace('device = "default"', 'device = "pulse"')
    )
    assert got.params.device == "pulse"


def test_empty_device_seeds_the_system_default(tmp_path: Path) -> None:
    # voxtype normalizes an empty [audio].device to the system default, and so
    # does the loader, so the picker reverse-maps it to the System-default row.
    got = _load(tmp_path, 'engine = "whisper"\n[audio]\ndevice = ""\n')
    assert got.params.device == "default"


def test_absent_device_seeds_the_system_default(tmp_path: Path) -> None:
    got = _load(tmp_path, 'engine = "whisper"\n[audio]\nmax_duration_secs = 60\n')
    assert got.params.device == "default"


def test_store_path_with_unknown_basename_kept_verbatim(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = "/nix/store/abc123-ggml-house-style.bin"
        """,
    )

    assert got.params.model == "/nix/store/abc123-ggml-house-style.bin"


def test_plain_catalog_model_name_passes_through(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = "base.en"
        """,
    )

    assert got.params.model == "base.en"


def test_unknown_plain_model_name_kept_verbatim(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = "large-v2"
        """,
    )

    assert got.params.model == "large-v2"


def test_model_paths_maps_whisper_store_path_to_catalog_name(tmp_path: Path) -> None:
    # The system file references the whisper model by absolute store path. The
    # loader must both seed the catalog NAME (existing behavior) and remember
    # name -> path so the availability probe and transcribe can use the bytes.
    got = _load(tmp_path, _SYSTEM_WHISPER_TOML)

    assert got.params.model == "small"
    assert got.model_paths == {
        (
            "whisper",
            "small",
        ): "/nix/store/cp89s185x1ykj4fi5a5mn9nlbvz1vwnn-ggml-small.bin"
    }


def test_model_paths_empty_for_plain_names(tmp_path: Path) -> None:
    # A name-based config provides no bytes of its own, nothing to remember.
    got = _load(tmp_path, _SYSTEM_PARAKEET_TOML)

    assert got.model_paths == {}


def test_model_paths_collects_both_engines(tmp_path: Path) -> None:
    # A parakeet system file still carries the merged [whisper] block. When
    # BOTH reference absolute paths, both models must be reachable.
    got = _load(
        tmp_path,
        """\
        engine = "parakeet"
        [parakeet]
        model = "/nix/store/abc123-parakeet-tdt-0.6b-v3"
        [whisper]
        model = "/nix/store/def456-ggml-small.bin"
        """,
    )

    assert got.model_paths == {
        ("whisper", "small"): "/nix/store/def456-ggml-small.bin",
        ("parakeet", "parakeet-tdt-0.6b-v3"): "/nix/store/abc123-parakeet-tdt-0.6b-v3",
    }


def test_model_paths_unknown_basename_keyed_verbatim(tmp_path: Path) -> None:
    # An off-catalog path stays verbatim in the combo, so the map must key on
    # that same verbatim string for the probe to find it.
    path = "/nix/store/abc123-ggml-house-style.bin"
    got = _load(
        tmp_path,
        f"""\
        engine = "whisper"
        [whisper]
        model = "{path}"
        """,
    )

    assert got.params.model == path
    assert got.model_paths == {("whisper", path): path}


def test_parakeet_store_dir_seeds_catalog_name_and_path(tmp_path: Path) -> None:
    # Store dirs carry the hash in the directory name itself
    # (/nix/store/<hash>-<model-id>). Map the trailing id back to the catalog
    # like the whisper ggml basename, and remember the dir for transcribe.
    path = "/nix/store/abc123-parakeet-unified-en-0.6b"
    got = _load(
        tmp_path,
        f"""\
        engine = "parakeet"
        [parakeet]
        model = "{path}"
        """,
    )

    assert got.params.engine == "parakeet"
    assert got.params.model == "parakeet-unified-en-0.6b"
    assert got.model_paths == {("parakeet", "parakeet-unified-en-0.6b"): path}


def test_parakeet_plain_dir_basename_maps_to_catalog(tmp_path: Path) -> None:
    # A non-store absolute dir whose basename IS the model id maps cleanly.
    got = _load(
        tmp_path,
        """\
        engine = "parakeet"
        [parakeet]
        model = "/opt/models/parakeet-tdt-0.6b-v3-int8"
        """,
    )

    assert got.params.model == "parakeet-tdt-0.6b-v3-int8"


def test_parakeet_int8_suffix_not_confused_with_base_variant(tmp_path: Path) -> None:
    # `…-v3` must not swallow `…-v3-int8` (or vice versa) when matching the
    # hash-prefixed store basename.
    got = _load(
        tmp_path,
        """\
        engine = "parakeet"
        [parakeet]
        model = "/nix/store/h4sh-parakeet-tdt-0.6b-v3-int8"
        """,
    )

    assert got.params.model == "parakeet-tdt-0.6b-v3-int8"


def test_parakeet_unknown_dir_kept_verbatim(tmp_path: Path) -> None:
    path = "/srv/models/my-finetuned-parakeet"
    got = _load(
        tmp_path,
        f"""\
        engine = "parakeet"
        [parakeet]
        model = "{path}"
        """,
    )

    assert got.params.model == path
    assert got.model_paths == {("parakeet", path): path}


def test_startup_model_paths_merge_user_under_system(tmp_path: Path) -> None:
    # The tuner's Apply writes a complete user config carrying the same store
    # path. A user file must contribute its mappings too (a system entry wins
    # a conflict since it is the baseline the tuner reports as "system").
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")
    environ, _user = _write_user_config(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = "/nix/store/aaa111-ggml-tiny.bin"
        """,
    )
    environ[ENV_VAR] = str(system)

    got = load_startup(environ=environ)

    assert got.model_paths == {
        (
            "whisper",
            "small",
        ): "/nix/store/cp89s185x1ykj4fi5a5mn9nlbvz1vwnn-ggml-small.bin",
        ("whisper", "tiny"): "/nix/store/aaa111-ggml-tiny.bin",
    }


def test_startup_without_user_config_uses_system_model_paths(tmp_path: Path) -> None:
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")
    environ = {
        ENV_VAR: str(system),
        "XDG_CONFIG_HOME": str(tmp_path / "empty-xdg"),
    }

    got = load_startup(environ=environ)

    assert got.model_paths == got.system.model_paths
    assert ("whisper", "small") in got.model_paths


def test_parakeet_system_file_seeds_parakeet_engine_and_model(tmp_path: Path) -> None:
    got = _load(tmp_path, _SYSTEM_PARAKEET_TOML)

    assert got.params.engine == "parakeet"
    assert got.params.model == "parakeet-unified-en-0.6b"
    # language still seeds from the (upstream-merged) whisper block. The
    # absent initial_prompt reads as empty.
    assert got.params.language == "en"
    assert got.params.initial_prompt == ""


def test_parakeet_without_table_uses_voxtype_default_model(tmp_path: Path) -> None:
    got = _load(tmp_path, 'engine = "parakeet"\n')

    assert got.params.engine == "parakeet"
    assert got.params.model == "parakeet-tdt-0.6b-v3"


def test_nemotron_system_file_seeds_engine_streaming_and_empty_model(
    tmp_path: Path,
) -> None:
    got = _load(tmp_path, _SYSTEM_NEMOTRON_TOML)

    assert got.params.engine == "nemotron"
    # No tuner catalog for nemotron: the model combo stays empty/disabled, so
    # the seeded model is empty rather than the store path (which would surface
    # as a bogus selectable row).
    assert got.params.model == ""
    assert got.params.streaming is True
    # Nemotron's language seeds from its own [nemotron].target_lang, NOT the
    # merged [whisper] block: this baseline's "auto" reads as Auto even though
    # [whisper].language is "en" (which belongs to a future whisper switch).
    assert got.params.language == "auto"


def test_nemotron_streaming_off_seeds_off(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "nemotron"
        [nemotron]
        model = "/nix/store/x-nemotron"
        streaming = false
        """,
    )

    assert got.params.engine == "nemotron"
    assert got.params.streaming is False


def test_nemotron_without_streaming_key_defaults_off(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "nemotron"
        [nemotron]
        model = "/nix/store/x-nemotron"
        """,
    )

    assert got.params.engine == "nemotron"
    assert got.params.streaming is False


def test_nemotron_seeds_language_from_its_target_lang(tmp_path: Path) -> None:
    # The nemotron picker seeds from [nemotron].target_lang (reverse-mapped to a
    # curated code), NOT the [whisper] block, so "de-DE" seeds "de" even though
    # [whisper].language here is "en".
    got = _load(
        tmp_path,
        """\
        engine = "nemotron"
        [whisper]
        language = "en"
        [nemotron]
        model = "/nix/store/x-nemotron"
        target_lang = "de-DE"
        """,
    )

    assert got.params.engine == "nemotron"
    assert got.params.language == "de"


def test_nemotron_unrepresentable_target_lang_seeds_auto(tmp_path: Path) -> None:
    # A locale outside the curated set has no picker row, so it reads as Auto
    # rather than surfacing a code the single-select picker can't show.
    got = _load(
        tmp_path,
        """\
        engine = "nemotron"
        [nemotron]
        model = "/nix/store/x-nemotron"
        target_lang = "ja-JP"
        """,
    )

    assert got.params.language == "auto"


def test_nemotron_bare_code_target_lang_seeds_that_code(tmp_path: Path) -> None:
    # A hand-written bare code (also a valid nemotron key) round-trips to itself.
    got = _load(
        tmp_path,
        """\
        engine = "nemotron"
        [nemotron]
        model = "/nix/store/x-nemotron"
        target_lang = "fr"
        """,
    )

    assert got.params.language == "fr"


def test_seed_controls_nemotron_language_checks_the_mapped_row() -> None:
    # A seeded nemotron "de" selection lights the DE checklist row (auto off),
    # so the popup and pill reflect the target_lang the daemon runs.
    got = seed_controls(
        replace(BUILTIN_DEFAULTS, engine="nemotron", model="", language="de")
    )

    assert got.language_auto is False
    assert dict(zip(got.languages, got.language_checked, strict=False))["de"] is True


def test_seed_controls_nemotron_streaming_has_empty_model_catalog() -> None:
    # Seeding a nemotron streaming baseline must keep the model combo empty (no
    # blank row from the empty selection) while carrying the streaming toggle.
    got = seed_controls(
        replace(BUILTIN_DEFAULTS, engine="nemotron", model="", streaming=True)
    )

    assert got.engines[got.engine_index] == "nemotron"
    assert got.models == []
    assert got.model_index == 0
    assert got.streaming is True


def test_vad_block_absent_means_vad_off(tmp_path: Path) -> None:
    # The module omits [vad] entirely when VAD is disabled, and voxtype's own
    # built-in default is enabled = false / threshold = 0.5. A loaded file's
    # missing keys must mean what the daemon would actually run with, not the
    # tuner's built-ins (vad on / 0.40).
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = "base.en"
        """,
    )

    assert got.loaded is True
    assert got.params.vad is False
    assert got.params.vad_threshold == 0.5


def test_partial_file_uses_voxtype_fallbacks_per_key(tmp_path: Path) -> None:
    got = _load(tmp_path, 'engine = "whisper"\n')

    assert got.loaded is True
    assert got.params == TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.5,
        max_duration=60,
    )


def test_type_mismatched_values_fall_back_per_key(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = 42
        language = 3.14
        initial_prompt = false
        [vad]
        enabled = "yes"
        threshold = "high"
        [audio]
        max_duration_secs = true
        """,
    )

    # Every bad value degrades alone. Note max_duration_secs = true must be
    # rejected (bool is an int subclass in Python) rather than seeding 1s.
    assert got.params == TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.5,
        max_duration=60,
    )


def test_integer_threshold_accepted_as_float(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [vad]
        enabled = true
        threshold = 1
        """,
    )

    assert got.params.vad is True
    assert got.params.vad_threshold == 1.0


def test_threshold_rounded_to_combo_precision(tmp_path: Path) -> None:
    # The threshold combo shows two decimals. Keep the seeded default at the
    # representable value so "unmodified" round-trips exactly through the UI.
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [vad]
        enabled = true
        threshold = 0.457
        """,
    )

    assert got.params.vad_threshold == 0.46


def test_language_array_joins_to_constrained_set(tmp_path: Path) -> None:
    # whisper.language = ["en", "de"] is voxtype's constrained auto-detect
    # (LanguageConfig::Multiple). The tuner carries it as the comma-joined form
    # its CLI --language accepts.
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = ["en", "de"]
        """,
    )

    assert got.params.language == "en,de"


def test_language_array_canonicalizes_to_catalog_order(tmp_path: Path) -> None:
    # The checklist serializes selections in catalog order, so the seeded value
    # must arrive in the same order or an untouched UI would read as modified.
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = ["de", "en"]
        """,
    )

    assert got.params.language == "en,de"


def test_language_array_off_catalog_codes_sort_after_catalog(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = ["ru", "en", "pt"]
        """,
    )

    assert got.params.language == "en,pt,ru"


def test_language_string_with_commas_canonicalizes_like_an_array(
    tmp_path: Path,
) -> None:
    # A hand-written `language = "de,en"` means the same constrained set as the
    # array form. Parse both through one canonicalizer.
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = "de,en"
        """,
    )

    assert got.params.language == "en,de"


def test_language_array_containing_auto_collapses_to_auto(tmp_path: Path) -> None:
    # "auto" means unconstrained detection. Constraining to a set that includes
    # it is contradictory, and the checklist cannot represent auto+codes.
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = ["auto", "en"]
        """,
    )

    assert got.params.language == "auto"


def test_language_array_dedupes(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = ["en", "en", "de"]
        """,
    )

    assert got.params.language == "en,de"


def test_language_empty_list_falls_back(tmp_path: Path) -> None:
    got = _load(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        language = []
        """,
    )

    assert got.params.language == "en"


def test_unknown_engine_falls_back_to_whisper(tmp_path: Path) -> None:
    # The module can only generate whisper/parakeet. Anything else is a
    # hand-edit the tuner can't represent as a system default.
    got = _load(tmp_path, 'engine = "banana"\n')

    assert got.params.engine == "whisper"


def test_non_string_engine_falls_back_to_whisper(tmp_path: Path) -> None:
    # A non-string engine value (here a TOML integer) is not a selectable
    # engine name, so it reads as the whisper fallback exactly like an unknown
    # name rather than leaking the raw non-string value into the seeded params.
    got = _load(tmp_path, "engine = 5\n")

    assert got.params.engine == "whisper"


def _write_user_config(tmp_path: Path, text: str) -> tuple[dict[str, str], Path]:
    """A tmp XDG_CONFIG_HOME with voxtype/config.toml holding ``text``.

    Returns the environ dict to inject plus the written path.
    """
    xdg = tmp_path / "xdg-config"
    (xdg / "voxtype").mkdir(parents=True)
    path = xdg / "voxtype" / "config.toml"
    path.write_text(dedent(text))
    return {"XDG_CONFIG_HOME": str(xdg)}, path


def test_user_config_path_honors_xdg_config_home(tmp_path: Path) -> None:
    got = user_config_path(environ={"XDG_CONFIG_HOME": str(tmp_path)})

    assert got == str(tmp_path / "voxtype" / "config.toml")


def test_startup_without_user_config_uses_baseline(tmp_path: Path) -> None:
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")
    environ = {
        ENV_VAR: str(system),
        "XDG_CONFIG_HOME": str(tmp_path / "empty-xdg"),
    }

    got = load_startup(environ=environ)

    assert got.system.loaded is True
    assert got.initial == got.system.params
    assert got.status == got.system.status


def test_startup_with_user_config_seeds_initial_values(tmp_path: Path) -> None:
    # A user who already applied overrides sees their CURRENT settings on
    # launch. The baseline stays the system file, so the indicators light up
    # for exactly the params the override changed.
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")
    environ, user = _write_user_config(
        tmp_path,
        """\
        engine = "whisper"
        [whisper]
        model = "base.en"
        language = "en"
        [vad]
        enabled = true
        threshold = 0.6
        [audio]
        max_duration_secs = 120
        """,
    )
    environ[ENV_VAR] = str(system)

    got = load_startup(environ=environ)

    assert got.system.params.model == "small"  # baseline untouched
    assert got.initial == TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="",
        vad=True,
        vad_threshold=0.6,
        max_duration=120,
    )
    assert got.status == f"User config: {user} · System defaults: {system}"


def test_startup_user_config_is_full_replacement_not_merge(tmp_path: Path) -> None:
    # voxtype does not merge config files: an override layers over voxtype's
    # BUILT-IN defaults, not over the system file. A user config that only
    # sets a threshold therefore runs base.en. The initial values must say
    # so instead of pretending the system model still applies.
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")
    environ, _user = _write_user_config(
        tmp_path,
        """\
        [vad]
        enabled = true
        threshold = 0.3
        """,
    )
    environ[ENV_VAR] = str(system)

    got = load_startup(environ=environ)

    assert got.initial.model == "base.en"
    assert got.initial.vad_threshold == 0.3
    assert got.system.params.model == "small"


def test_startup_user_config_malformed_falls_back_to_baseline(tmp_path: Path) -> None:
    system = _write(tmp_path, _SYSTEM_WHISPER_TOML, name="system.toml")
    environ, _user = _write_user_config(tmp_path, "engine = [broken")
    environ[ENV_VAR] = str(system)

    got = load_startup(environ=environ)

    assert got.initial == got.system.params
    assert got.status == (
        f"User config: unreadable, using system defaults · System defaults: {system}"
    )


def test_seed_controls_builtin_matches_todays_ui() -> None:
    got = seed_controls(BUILTIN_DEFAULTS)

    assert got == SeededControls(
        engines=list(params.ENGINES),
        engine_index=0,
        models=params.models_for("whisper"),
        model_index=0,
        languages=list(params.LANGUAGES),
        language_auto=False,
        language_checked=[True, False, False, False],
        vad_thresholds=list(params.VAD_THRESHOLDS),
        vad_threshold_index=1,
        max_durations=[str(d) for d in params.MAX_DURATIONS],
        max_duration_index=2,
        vad=True,
        prompt="",
        streaming=False,
    )


def test_seed_controls_selects_system_model_in_catalog() -> None:
    got = seed_controls(replace(BUILTIN_DEFAULTS, model="small"))

    assert got.models == params.models_for("whisper")
    assert got.models[got.model_index] == "small"


def test_seed_controls_appends_custom_model_verbatim() -> None:
    path = "/nix/store/abc123-ggml-house-style.bin"
    got = seed_controls(replace(BUILTIN_DEFAULTS, model=path))

    assert got.models == [*params.models_for("whisper"), path]
    assert got.model_index == len(got.models) - 1


def test_seed_controls_inserts_offcatalog_threshold_sorted() -> None:
    got = seed_controls(replace(BUILTIN_DEFAULTS, vad_threshold=0.45))

    assert got.vad_thresholds == ["0.30", "0.40", "0.45", "0.50", "0.60", "0.70"]
    assert got.vad_thresholds[got.vad_threshold_index] == "0.45"


def test_seed_controls_inserts_offcatalog_duration_sorted() -> None:
    got = seed_controls(replace(BUILTIN_DEFAULTS, max_duration=90))

    assert got.max_durations == ["15", "30", "60", "90", "120"]
    assert got.max_durations[got.max_duration_index] == "90"


def test_seed_controls_appends_custom_language() -> None:
    got = seed_controls(replace(BUILTIN_DEFAULTS, language="ru"))

    assert got.languages == [*params.LANGUAGES, "ru"]
    assert got.language_auto is False
    assert got.language_checked == [False] * len(params.LANGUAGES) + [True]


def test_seed_controls_language_auto_checks_nothing() -> None:
    got = seed_controls(replace(BUILTIN_DEFAULTS, language="auto"))

    assert got.languages == list(params.LANGUAGES)
    assert got.language_auto is True
    assert got.language_checked == [False] * len(params.LANGUAGES)


def test_seed_controls_multi_language_checks_each_member() -> None:
    got = seed_controls(replace(BUILTIN_DEFAULTS, language="en,de"))

    assert got.languages == list(params.LANGUAGES)
    assert got.language_auto is False
    checked = dict(zip(got.languages, got.language_checked, strict=True))
    assert checked == {"en": True, "de": True, "fr": False, "es": False}


def test_seed_controls_multi_language_off_catalog_member_selectable() -> None:
    # Every member of a constrained set must be a real row, or unchecking one
    # of the others could never re-check it.
    got = seed_controls(replace(BUILTIN_DEFAULTS, language="en,ru"))

    assert got.languages == [*params.LANGUAGES, "ru"]
    checked = dict(zip(got.languages, got.language_checked, strict=True))
    assert checked["en"] is True
    assert checked["ru"] is True


def test_seed_controls_language_rows_union_both_param_sets() -> None:
    # Startup shows the user's languages, Reset the baseline's. One stable
    # row list must carry both selections.
    baseline = replace(BUILTIN_DEFAULTS, language="en,ru")
    initial = replace(BUILTIN_DEFAULTS, language="pt")

    at_initial = seed_controls(initial, also=baseline)
    at_baseline = seed_controls(baseline, also=initial)

    assert at_initial.languages == at_baseline.languages
    assert at_initial.languages == [*params.LANGUAGES, "pt", "ru"]
    assert (
        dict(zip(at_initial.languages, at_initial.language_checked, strict=True))["pt"]
        is True
    )
    checked_baseline = dict(
        zip(at_baseline.languages, at_baseline.language_checked, strict=True)
    )
    assert checked_baseline["en"] is True
    assert checked_baseline["ru"] is True


def test_seed_controls_parakeet_defaults() -> None:
    got = seed_controls(
        replace(BUILTIN_DEFAULTS, engine="parakeet", model="parakeet-unified-en-0.6b")
    )

    assert got.engines[got.engine_index] == "parakeet"
    assert got.models == params.models_for("parakeet")
    assert got.models[got.model_index] == "parakeet-unified-en-0.6b"


def test_seed_controls_also_unions_off_catalog_values() -> None:
    # Startup shows the user's values, Reset the baseline's. One stable
    # catalog must carry both, whichever side is selected.
    baseline_path = "/nix/store/abc123-ggml-house-style.bin"
    baseline = replace(BUILTIN_DEFAULTS, model=baseline_path, vad_threshold=0.45)
    initial = replace(BUILTIN_DEFAULTS, model="small", vad_threshold=0.35)

    at_initial = seed_controls(initial, also=baseline)
    at_baseline = seed_controls(baseline, also=initial)

    # Same catalogs from both directions. Only the selection differs.
    assert at_initial.models == at_baseline.models
    assert baseline_path in at_initial.models
    assert at_initial.models[at_initial.model_index] == "small"
    assert at_baseline.models[at_baseline.model_index] == baseline_path
    assert at_initial.vad_thresholds == at_baseline.vad_thresholds
    assert at_initial.vad_thresholds == [
        "0.30",
        "0.35",
        "0.40",
        "0.45",
        "0.50",
        "0.60",
        "0.70",
    ]
    assert at_initial.vad_thresholds[at_initial.vad_threshold_index] == "0.35"
    assert at_baseline.vad_thresholds[at_baseline.vad_threshold_index] == "0.45"


def test_model_catalog_for_includes_also_params_custom_model() -> None:
    baseline = replace(BUILTIN_DEFAULTS, model="small")
    initial = replace(BUILTIN_DEFAULTS, model="/nix/store/xyz-ggml-custom.bin")

    models, index = model_catalog_for("whisper", baseline, also=initial)

    assert "/nix/store/xyz-ggml-custom.bin" in models
    assert models[index] == "small"


def test_model_catalog_for_other_engine_is_plain_catalog() -> None:
    defaults = replace(BUILTIN_DEFAULTS, engine="whisper", model="small")

    models, index = model_catalog_for("parakeet", defaults)

    assert models == params.models_for("parakeet")
    assert index == 0


def test_model_catalog_for_nemotron_is_empty() -> None:
    models, index = model_catalog_for("nemotron", BUILTIN_DEFAULTS)

    assert models == []
    assert index == 0


def test_model_catalog_for_default_engine_selects_default_model() -> None:
    path = "/nix/store/abc123-ggml-house-style.bin"
    defaults = replace(BUILTIN_DEFAULTS, model=path)

    models, index = model_catalog_for("whisper", defaults)

    assert models[index] == path


def test_seeded_language_round_trips_through_checklist_serialization() -> None:
    # The invariant that keeps the modified indicator honest: pushing a seeded
    # value into the checklist and serializing the untouched checklist back
    # must reproduce the seeded string exactly, including off-catalog codes
    # and multi-value sets in any config order.
    for language in ("auto", "en", "en,de", "en,pt,ru", "de,fr,es"):
        got = seed_controls(replace(BUILTIN_DEFAULTS, language=language))
        assert (
            serialize_language(got.language_auto, got.languages, got.language_checked)
            == language
        ), language


def test_modified_fields_empty_when_equal() -> None:
    assert modified_fields(BUILTIN_DEFAULTS, BUILTIN_DEFAULTS) == frozenset()


def test_modified_fields_flags_exactly_the_changed_field() -> None:
    edits = [
        ("engine", replace(BUILTIN_DEFAULTS, engine="parakeet")),
        ("model", replace(BUILTIN_DEFAULTS, model="small")),
        ("language", replace(BUILTIN_DEFAULTS, language="de")),
        ("initial_prompt", replace(BUILTIN_DEFAULTS, initial_prompt="hello")),
        ("vad", replace(BUILTIN_DEFAULTS, vad=False)),
        ("vad_threshold", replace(BUILTIN_DEFAULTS, vad_threshold=0.7)),
        ("max_duration", replace(BUILTIN_DEFAULTS, max_duration=120)),
    ]
    for field, current in edits:
        assert modified_fields(current, BUILTIN_DEFAULTS) == frozenset({field}), field


def test_modified_fields_threshold_survives_combo_string_roundtrip() -> None:
    # The UI reads the threshold back as its combo string ("0.40"). Coercion
    # through build_params must compare equal to the seeded float.
    current = build_params(
        engine=BUILTIN_DEFAULTS.engine,
        model=BUILTIN_DEFAULTS.model,
        language=BUILTIN_DEFAULTS.language,
        prompt=BUILTIN_DEFAULTS.initial_prompt,
        vad=BUILTIN_DEFAULTS.vad,
        vad_threshold="0.40",
        max_duration="60",
    )

    assert modified_fields(current, BUILTIN_DEFAULTS) == frozenset()
