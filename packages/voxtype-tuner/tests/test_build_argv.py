"""Tests for the CLI argv builder and parameter catalogs.

The load-bearing invariant is ordering: every GLOBAL flag must precede the
`transcribe <wav>` subcommand, because voxtype only accepts global flags before
the subcommand. Each test asserts the exact list so a reordering regression
fails loudly.
"""

import tomllib

from voxtype_tuner.params import (
    ENGINES,
    LANGUAGES,
    MAX_DURATIONS,
    NEMOTRON_TARGET_LANGS,
    VAD_THRESHOLDS,
    TranscribeParams,
    build_argv,
    models_for,
    nemotron_config_toml,
    nemotron_language_from_target,
    nemotron_target_lang,
    parakeet_config_toml,
    streaming_capable,
    whisper_config_toml,
)


def test_whisper_vad_on_with_prompt_emits_exact_argv() -> None:
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="hello",
        vad=True,
        vad_threshold=0.4,
        max_duration=60,
    )
    assert build_argv(p, "/tmp/s1.wav") == [
        "voxtype",
        "--engine",
        "whisper",
        "--model",
        "base.en",
        "--language",
        "en",
        "--initial-prompt",
        "hello",
        "--vad",
        "--vad-threshold",
        "0.40",
        "--max-duration",
        "60",
        "transcribe",
        "/tmp/s1.wav",
    ]


def test_parakeet_vad_off_empty_prompt_omits_optional_flags() -> None:
    p = TranscribeParams(
        engine="parakeet",
        model="parakeet-tdt-0.6b-v3-int8",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    argv = build_argv(p, "/tmp/s1.wav")
    assert argv == [
        "voxtype",
        "--engine",
        "parakeet",
        "--model",
        "parakeet-tdt-0.6b-v3-int8",
        "--language",
        "en",
        "--max-duration",
        "60",
        "transcribe",
        "/tmp/s1.wav",
    ]
    assert "--vad" not in argv
    assert "--vad-threshold" not in argv
    assert "--initial-prompt" not in argv


def test_whitespace_only_prompt_omits_initial_prompt() -> None:
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="   \t\n  ",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    assert "--initial-prompt" not in build_argv(p, "/tmp/s1.wav")


def test_nemotron_routes_through_config_and_uses_voxtype_bin() -> None:
    # There is NO separate nemotron binary: the same fork `voxtype` runs every
    # engine, and nemotron selects its model EXCLUSIVELY through a mandatory
    # [nemotron] config passed with the root -c flag (transcribe.py generates
    # it). So the argv leads with the plain voxtype_bin, carries -c among the
    # globals, and drops --model entirely, exactly like the parakeet route.
    p = TranscribeParams(
        engine="nemotron",
        model="",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    argv = build_argv(
        p, "/tmp/s1.wav", voxtype_bin="/opt/vt/voxtype", config_path="/tmp/nem.toml"
    )
    assert argv == [
        "/opt/vt/voxtype",
        "-c",
        "/tmp/nem.toml",
        "--engine",
        "nemotron",
        "--language",
        "en",
        "--max-duration",
        "60",
        "transcribe",
        "/tmp/s1.wav",
    ]
    assert "--model" not in argv
    assert "voxtype-nemotron" not in argv
    # -c is a global flag: it must precede the transcribe subcommand.
    assert argv.index("-c") < argv.index("transcribe")


def test_language_auto_passes_through() -> None:
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="auto",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=30,
    )
    argv = build_argv(p, "/tmp/s1.wav")
    assert argv[argv.index("--language") + 1] == "auto"


def test_language_constrained_set_passes_comma_joined() -> None:
    # voxtype's --language accepts comma-separated codes
    # (LanguageConfig::from_comma_separated) for constrained auto-detect. The
    # serialized multi-selection must reach the CLI as ONE argv entry.
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en,de",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=30,
    )
    argv = build_argv(p, "/tmp/s1.wav")
    assert argv[argv.index("--language") + 1] == "en,de"


def test_custom_voxtype_bin_replaces_base() -> None:
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    assert build_argv(p, "/tmp/s1.wav", voxtype_bin="/nix/store/x/bin/voxtype")[0] == (
        "/nix/store/x/bin/voxtype"
    )


def test_vad_threshold_formats_to_two_decimals() -> None:
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="",
        vad=True,
        vad_threshold=0.5,
        max_duration=60,
    )
    argv = build_argv(p, "/tmp/s1.wav")
    assert argv[argv.index("--vad-threshold") + 1] == "0.50"


def test_catalogs_match_contract() -> None:
    assert ENGINES == ["whisper", "parakeet", "nemotron"]
    # The checkable codes. "auto" is a selection MODE (the popup's exclusive
    # first row), not a language, so it is no longer a catalog entry.
    assert LANGUAGES == ["en", "de", "fr", "es"]
    assert VAD_THRESHOLDS == ["0.30", "0.40", "0.50", "0.60", "0.70"]
    assert MAX_DURATIONS == [15, 30, 60, 120]


def test_models_for_whisper() -> None:
    assert models_for("whisper") == [
        "tiny",
        "tiny.en",
        "base",
        "base.en",
        "small",
        "small.en",
        "medium",
        "medium.en",
        "large-v3",
        "large-v3-turbo",
    ]


def test_models_for_parakeet() -> None:
    assert models_for("parakeet") == [
        "parakeet-tdt-0.6b-v2",
        "parakeet-tdt-0.6b-v2-int8",
        "parakeet-tdt-0.6b-v3",
        "parakeet-tdt-0.6b-v3-int8",
        "parakeet-unified-en-0.6b",
    ]


def test_models_for_nemotron_is_empty() -> None:
    assert models_for("nemotron") == []


def test_parakeet_with_config_emits_dash_c_and_omits_model() -> None:
    # voxtype's top-level --model is whisper-only: a parakeet name is WARNed
    # about and dropped, so parakeet model selection must come through a
    # [parakeet] config passed with the root -c flag. When a config_path is
    # given, build_argv emits `-c <path>` among the globals (before transcribe)
    # and drops --model entirely.
    p = TranscribeParams(
        engine="parakeet",
        model="parakeet-tdt-0.6b-v3",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    argv = build_argv(p, "/tmp/s1.wav", config_path="/tmp/pk.toml")
    assert argv == [
        "voxtype",
        "-c",
        "/tmp/pk.toml",
        "--engine",
        "parakeet",
        "--language",
        "en",
        "--max-duration",
        "60",
        "transcribe",
        "/tmp/s1.wav",
    ]
    assert "--model" not in argv
    # -c is a global flag: it must precede the transcribe subcommand.
    assert argv.index("-c") < argv.index("transcribe")


def test_parakeet_config_keeps_optional_globals() -> None:
    # The other globals (language, prompt, vad, max-duration) are harmless for
    # parakeet and must survive alongside -c. Only --model is dropped.
    p = TranscribeParams(
        engine="parakeet",
        model="parakeet-unified-en-0.6b",
        language="de",
        initial_prompt="notes",
        vad=True,
        vad_threshold=0.5,
        max_duration=120,
    )
    argv = build_argv(p, "/tmp/s1.wav", config_path="/tmp/pk.toml")
    assert argv == [
        "voxtype",
        "-c",
        "/tmp/pk.toml",
        "--engine",
        "parakeet",
        "--language",
        "de",
        "--initial-prompt",
        "notes",
        "--vad",
        "--vad-threshold",
        "0.50",
        "--max-duration",
        "120",
        "transcribe",
        "/tmp/s1.wav",
    ]
    assert "--model" not in argv


def test_whisper_ignores_config_path_absence() -> None:
    # The whisper path is untouched by the new parameter: no config_path is ever
    # passed for whisper, so it still emits --model and no -c.
    p = TranscribeParams(
        engine="whisper",
        model="base.en",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    argv = build_argv(p, "/tmp/s1.wav")
    assert "-c" not in argv
    assert argv[argv.index("--model") + 1] == "base.en"


def test_whisper_with_config_emits_dash_c_and_omits_model() -> None:
    # A store-path whisper model can only be selected through a config file:
    # the top-level --model flag validates against the bundled name catalog
    # (is_valid_model) and silently drops anything else. With a config_path,
    # --model must vanish from the argv exactly like the parakeet route.
    p = TranscribeParams(
        engine="whisper",
        model="small",
        language="en",
        initial_prompt="",
        vad=False,
        vad_threshold=0.4,
        max_duration=60,
    )
    argv = build_argv(p, "/tmp/s1.wav", config_path="/tmp/w.toml")
    assert argv == [
        "voxtype",
        "-c",
        "/tmp/w.toml",
        "--engine",
        "whisper",
        "--language",
        "en",
        "--max-duration",
        "60",
        "transcribe",
        "/tmp/s1.wav",
    ]
    assert "--model" not in argv


def test_whisper_config_toml_pins_model_path() -> None:
    # voxtype's whisper resolve_model_path accepts an absolute .bin path from
    # the config's [whisper] model key (is_absolute && exists). This is the
    # sanctioned route for store-path models.
    cfg = tomllib.loads(whisper_config_toml("/nix/store/abc-ggml-small.bin"))
    assert cfg["engine"] == "whisper"
    assert cfg["whisper"]["model"] == "/nix/store/abc-ggml-small.bin"


def test_parakeet_config_toml_path_overrides_model_value() -> None:
    # For a system-provisioned parakeet model the config's model value must be
    # the absolute store DIR, while streaming detection keys on the catalog
    # NAME (the path alone can't reveal the unified loader requirement).
    cfg = tomllib.loads(
        parakeet_config_toml(
            "parakeet-unified-en-0.6b", path="/nix/store/abc-parakeet-unified-en-0.6b"
        )
    )
    assert cfg["parakeet"]["model"] == "/nix/store/abc-parakeet-unified-en-0.6b"
    assert cfg["parakeet"]["streaming"] is True

    cfg = tomllib.loads(
        parakeet_config_toml(
            "parakeet-tdt-0.6b-v3", path="/nix/store/abc-parakeet-tdt-0.6b-v3"
        )
    )
    assert cfg["parakeet"]["model"] == "/nix/store/abc-parakeet-tdt-0.6b-v3"
    assert "streaming" not in cfg["parakeet"]


def test_streaming_capable_mirrors_voxtype_registry() -> None:
    # Mirrors voxtype's is_streaming_compatible_parakeet: only the unified
    # model ships the tokenizer.model the cache-aware pipeline needs. Unknown
    # names (custom dirs) read as not capable, same as upstream.
    assert streaming_capable("parakeet-unified-en-0.6b") is True
    assert streaming_capable("parakeet-tdt-0.6b-v2") is False
    assert streaming_capable("parakeet-tdt-0.6b-v2-int8") is False
    assert streaming_capable("parakeet-tdt-0.6b-v3") is False
    assert streaming_capable("parakeet-tdt-0.6b-v3-int8") is False
    assert streaming_capable("/srv/models/custom") is False


def test_parakeet_config_toml_normal_model_has_no_streaming() -> None:
    cfg = tomllib.loads(parakeet_config_toml("parakeet-tdt-0.6b-v3"))
    assert cfg["engine"] == "parakeet"
    assert cfg["parakeet"]["model"] == "parakeet-tdt-0.6b-v3"
    # A normal batch model must not carry streaming keys. That path is only for
    # the unified variant below.
    assert "streaming" not in cfg["parakeet"]


def test_parakeet_config_toml_unified_enables_streaming_profile() -> None:
    # parakeet-unified-en-0.6b has encoder.onnx/decoder_joint.onnx/tokenizer.model
    # naming the BATCH loader can't auto-detect, so it must run through the
    # streaming ParakeetUnified transcriber with the crate's blessed
    # 56/560/56-frame context profile.
    cfg = tomllib.loads(parakeet_config_toml("parakeet-unified-en-0.6b"))
    assert cfg["engine"] == "parakeet"
    assert cfg["parakeet"]["model"] == "parakeet-unified-en-0.6b"
    assert cfg["parakeet"]["streaming"] is True
    assert cfg["parakeet"]["streaming_chunk_secs"] == 0.56
    assert cfg["parakeet"]["streaming_left_context_secs"] == 5.6
    assert cfg["parakeet"]["streaming_right_context_secs"] == 0.56


def test_nemotron_config_toml_pins_model_and_defaults() -> None:
    # The mandatory [nemotron] section voxtype refuses to run without. The model
    # is the absolute store DIR of the five-file ONNX export. The target_lang
    # defaults to "auto" (the tuner disables language for nemotron) and the batch
    # transcribe path is non-streaming.
    cfg = tomllib.loads(
        nemotron_config_toml("/nix/store/abc-nemotron-3.5-asr-streaming-0.6b")
    )
    assert cfg["engine"] == "nemotron"
    assert cfg["nemotron"]["model"] == "/nix/store/abc-nemotron-3.5-asr-streaming-0.6b"
    assert cfg["nemotron"]["target_lang"] == "auto"
    assert cfg["nemotron"]["streaming"] is False


def test_nemotron_config_toml_carries_explicit_lang_and_streaming() -> None:
    # A caller can still pin a concrete locale and enable streaming. Both land
    # verbatim so the multilingual model's prompt dictionary and the daemon see
    # what was asked for.
    cfg = tomllib.loads(
        nemotron_config_toml("/models/nem", target_lang="de-DE", streaming=True)
    )
    assert cfg["nemotron"]["model"] == "/models/nem"
    assert cfg["nemotron"]["target_lang"] == "de-DE"
    assert cfg["nemotron"]["streaming"] is True


# The tuner's curated codes mapped to the full BCP-47-ish locales. These exact
# values were confirmed against the real fork: a batch transcribe with each was
# accepted and ran (model loaded with target_lang=<locale>), while an invalid
# locale was rejected at load. See the branch's proof. Every key is also a
# member of parakeet-rs 0.3.6's PROMPT_DICTIONARY (src/nemotron.rs).
_CURATED_NEMOTRON_LOCALES = {
    "en": "en-US",
    "de": "de-DE",
    "fr": "fr-FR",
    "es": "es-ES",
}


def test_nemotron_target_langs_table_matches_the_curated_language_set() -> None:
    # The nemotron picker offers the SAME curated codes as whisper's, each
    # mapped to a nemotron locale (no code left unmapped, none invented).
    assert set(NEMOTRON_TARGET_LANGS) == set(LANGUAGES)
    assert NEMOTRON_TARGET_LANGS == _CURATED_NEMOTRON_LOCALES


def test_nemotron_target_lang_maps_each_curated_code_to_its_locale() -> None:
    for code, locale in _CURATED_NEMOTRON_LOCALES.items():
        assert nemotron_target_lang(code) == locale


def test_nemotron_target_lang_collapses_auto_multi_and_unknown() -> None:
    # Nemotron is single-target: only exactly one curated code yields a locale.
    # Everything else (Auto, the empty value, a multi-code set the single-select
    # picker can't build, or a code with no nemotron equivalent) is "auto".
    assert nemotron_target_lang("auto") == "auto"
    assert nemotron_target_lang("") == "auto"
    assert nemotron_target_lang("en,de") == "auto"
    assert nemotron_target_lang("pt") == "auto"


def test_nemotron_language_from_target_reverse_maps_locale_and_bare_code() -> None:
    # Seeding the picker: both the emitted locale and a hand-written bare code
    # round-trip back to the curated code.
    for code, locale in _CURATED_NEMOTRON_LOCALES.items():
        assert nemotron_language_from_target(locale) == code
        assert nemotron_language_from_target(code) == code


def test_nemotron_language_from_target_unrepresentable_reads_auto() -> None:
    # auto, blank, and any non-curated locale have no single-select picker row.
    assert nemotron_language_from_target("auto") == "auto"
    assert nemotron_language_from_target("") == "auto"
    assert nemotron_language_from_target("en-GB") == "auto"
    assert nemotron_language_from_target("ja-JP") == "auto"


def test_nemotron_language_mapping_round_trips_for_curated_codes() -> None:
    # The invariant behind an honest seed/Apply round-trip: reverse-mapping the
    # locale Apply would write reproduces the picker's curated code exactly.
    for code in LANGUAGES:
        assert nemotron_language_from_target(nemotron_target_lang(code)) == code
