"""Parameter catalogs and the voxtype CLI argv builder.

The tuner drives voxtype through its CLI. voxtype only accepts global flags
*before* the subcommand, so :func:`build_argv` emits every configured flag ahead
of the trailing ``transcribe <wav>``. That ordering is the contract Track A's
UI integrates against.
"""

from __future__ import annotations

from dataclasses import dataclass

# "nemotron" is the fork's multilingual streaming engine. It goes LAST so the UI
# defaults to whisper. It carries no tuner model catalog (its model is
# Nix-provisioned and pinned by store path, not chosen here) and transcribes
# through a mandatory [nemotron] config section, exactly like parakeet.
ENGINES: list[str] = ["whisper", "parakeet", "nemotron"]

# The checkable language codes the popup offers out of the box, "en" first
# (the default). "auto" is a selection MODE (whisper's unconstrained
# detection, the popup's exclusive first row), not a catalog entry.
LANGUAGES: list[str] = ["en", "de", "fr", "es"]

# The serialized --language value for unconstrained detection. voxtype's
# LanguageConfig also accepts comma-separated codes ("en,de") for CONSTRAINED
# auto-detection. The multi-checked popup state maps onto that form.
AUTO_LANGUAGE = "auto"


def language_codes(language: str) -> list[str]:
    """Parse a serialized ``--language`` value into its language codes.

    ``"auto"`` (voxtype's unconstrained detection) has no codes. A set that
    names ``auto`` alongside codes is contradictory (and unrepresentable in
    the checklist), so it collapses to unconstrained too. Duplicates are
    dropped keeping first occurrence.
    """
    codes = [c.strip() for c in language.split(",") if c.strip()]
    if AUTO_LANGUAGE in codes:
        return []
    return list(dict.fromkeys(codes))


# The tuner's curated language codes (:data:`LANGUAGES`) mapped to nemotron's
# own ``target_lang`` locale keys. Nemotron takes a SINGLE BCP-47-ish locale (or
# ``"auto"``), not whisper's multi-code set, so its picker is single-select and
# each choice resolves to exactly one of these keys. Every value here is a
# verified key in parakeet-rs 0.3.6's ``PROMPT_DICTIONARY`` (src/nemotron.rs),
# the exact dictionary ``Nemotron::set_target_lang`` matches against, so voxtype
# accepts each one. The module's ``nemotronTargetLang`` documents this same
# locale form (default ``"auto"``, example ``"de-DE"``). A curated code with no
# nemotron equivalent is deliberately absent, so it maps to ``"auto"`` rather
# than emitting a locale the model would reject at load.
NEMOTRON_TARGET_LANGS: dict[str, str] = {
    "en": "en-US",
    "de": "de-DE",
    "fr": "fr-FR",
    "es": "es-ES",
}

# Reverse of :data:`NEMOTRON_TARGET_LANGS` for seeding the picker from a config's
# ``target_lang``. Both the emitted locale (``"de-DE"``) and the bare curated
# code (``"de"``) a hand-written or module config might carry map back to the
# curated code. Any other locale (``"en-GB"``, ``"ja-JP"``) and ``"auto"`` have
# no place in the curated single-select picker, so they read as Auto.
_NEMOTRON_CODE_BY_LANG: dict[str, str] = {
    **{locale: code for code, locale in NEMOTRON_TARGET_LANGS.items()},
    **{code: code for code in NEMOTRON_TARGET_LANGS},
}


def nemotron_target_lang(language: str) -> str:
    """Map the picker's language selection to nemotron's ``target_lang`` locale.

    ``language`` is the tuner's serialized ``--language`` value. Nemotron is
    single-target, so anything that is not exactly one curated code
    (``"auto"``, the empty/blank value, or a multi-code set the single-select
    picker can never produce) collapses to ``"auto"`` (the model detects the
    language itself). A single curated code becomes its
    :data:`NEMOTRON_TARGET_LANGS` locale. An unrecognized code with no nemotron
    equivalent also collapses to ``"auto"`` rather than emitting a locale
    voxtype would reject at load.
    """
    codes = language_codes(language)
    if len(codes) != 1:
        return AUTO_LANGUAGE
    return NEMOTRON_TARGET_LANGS.get(codes[0], AUTO_LANGUAGE)


def nemotron_language_from_target(target_lang: str) -> str:
    """Reverse-map a config's ``[nemotron] target_lang`` to the picker's language.

    The inverse of :func:`nemotron_target_lang` for the seed round-trip: a
    curated locale (``"de-DE"``) or its bare code (``"de"``) becomes the curated
    code (``"de"``). ``"auto"``, a blank value, or any non-curated locale
    (``"en-GB"``, ``"ja-JP"``) has no representation in the curated single-select
    picker, so it reads as Auto (``"auto"``).
    """
    return _NEMOTRON_CODE_BY_LANG.get(target_lang.strip(), AUTO_LANGUAGE)


# Pre-formatted so the UI can show them verbatim. "0.40" is the default and
# matches modules/nixos/voxtype.nix's slightly-more-sensitive-than-upstream 0.4.
VAD_THRESHOLDS: list[str] = ["0.30", "0.40", "0.50", "0.60", "0.70"]

# Recording cap in seconds. 60 is the default.
MAX_DURATIONS: list[int] = [15, 30, 60, 120]

# voxtype's full downloadable whisper catalog, verbatim from its downloader
# registry (src/setup/model.rs `MODELS`, the list is_valid_model /
# valid_model_names check against). The legacy load-time aliases large /
# large-v1 / large-v2 are deliberately NOT offered: voxtype recognises them
# when already on disk but its downloader has no URL for them, so a Download
# on those entries could only fail.
_WHISPER_MODELS: list[str] = [
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

# voxtype's full parakeet catalog, verbatim from src/setup/model.rs
# `PARAKEET_MODELS`.
_PARAKEET_MODELS: list[str] = [
    "parakeet-tdt-0.6b-v2",
    "parakeet-tdt-0.6b-v2-int8",
    "parakeet-tdt-0.6b-v3",
    "parakeet-tdt-0.6b-v3-int8",
    # The only streaming-capable parakeet variant (and the nixos module default).
    "parakeet-unified-en-0.6b",
]


# Streaming-capable parakeet variants, mirroring the per-model
# `streaming_compatible` flag in voxtype's registry (src/setup/model.rs
# PARAKEET_MODELS / is_streaming_compatible_parakeet): capable means the model
# ships a tokenizer.model alongside its encoder/decoder, which parakeet-rs's
# cache-aware ParakeetUnified pipeline requires at load time. Its files are
# also named encoder.onnx/decoder_joint.onnx, a convention voxtype's BATCH
# parakeet loader (which probes for encoder-model.onnx) can't auto-detect, so
# file transcription of this variant must run through the streaming
# transcriber too (see parakeet_config_toml).
_PARAKEET_STREAMING_MODELS: frozenset[str] = frozenset({"parakeet-unified-en-0.6b"})


def streaming_capable(model: str) -> bool:
    """Whether ``model`` can run voxtype's cache-aware streaming pipeline.

    Mirrors voxtype's ``is_streaming_compatible_parakeet``: a registry
    allowlist, so unknown names (custom absolute dirs included) read as not
    capable. Upstream can't validate those ahead of time either.
    """
    return model in _PARAKEET_STREAMING_MODELS


def engine_can_stream(engine: str, model: str) -> bool:
    """Whether ``(engine, model)`` can run voxtype's live streaming pipeline.

    The single engine-aware predicate the UI gate and the daemon config guard
    share, so they can never disagree about which selections may stream:

    - parakeet streams only through its one allowlisted cache-aware model
      (:func:`streaming_capable`).
    - nemotron's sole provisioned model always streams, and crucially its
      streaming config is JUST ``streaming = true`` (no mel-frame context
      profile, unlike parakeet), so there is no per-model constraint to check.
    - every other engine has no streaming pipeline at all.
    """
    if engine == "parakeet":
        return streaming_capable(model)
    # Nemotron's one provisioned model always streams. Every other engine has
    # no streaming pipeline.
    return engine == "nemotron"


# The one streaming-context profile parakeet-rs accepts: 56/560/56 mel frames,
# the only chunk/left/right combination that satisfies its
# frames-divisible-by-8 constraint (voxtype's own compiled defaults 0.5/1.5/0.5
# violate it and refuse to load). These exact values match
# modules/nixos/voxtype.nix's streaming block, so a config that turns streaming
# on carries a loadable profile even when the baseline had none to preserve.
STREAMING_CONTEXT_SECS: dict[str, float] = {
    "streaming_chunk_secs": 0.56,
    "streaming_left_context_secs": 5.6,
    "streaming_right_context_secs": 0.56,
}


def whisper_config_toml(model: str) -> str:
    """Render the minimal ``[whisper]`` config that selects ``model``.

    The route for absolute .bin paths: voxtype's top-level ``--model`` flag
    validates its argument against the bundled name catalog (is_valid_model)
    and silently drops anything else, while the config key feeds
    resolve_model_path, whose first check accepts any absolute existing path.
    voxtype layers a ``-c`` config over its built-in defaults, so this partial
    file is complete as far as model selection goes. Every other tuner param
    still arrives as a CLI flag.
    """
    lines = ['engine = "whisper"', "", "[whisper]", f'model = "{model}"']
    return "\n".join(lines) + "\n"


def parakeet_config_toml(model: str, path: str | None = None) -> str:
    """Render the minimal ``[parakeet]`` config that selects ``model``.

    voxtype's top-level ``--model`` flag is whisper-only: a parakeet name is
    warned about and dropped, so parakeet model selection happens EXCLUSIVELY
    through a ``[parakeet]`` config section. ``model`` names a directory resolved
    under voxtype's models dir. ``path``, when given, replaces it as the config
    value with the absolute model directory (a system-provisioned store dir),
    while the capability check below still keys on the catalog NAME, because the
    path alone cannot reveal it.

    ``parakeet-unified-en-0.6b`` additionally needs ``streaming = true`` (its file
    naming defeats the batch loader, see ``streaming_capable``) with the
    crate's blessed 56/560/56-frame context profile (voxtype's own
    streaming-context defaults violate parakeet-rs's frames-divisible-by-8
    constraint and refuse to load), so these exact values (matching
    modules/nixos/voxtype.nix's streaming profile) are required for that one
    model.
    """
    lines = ['engine = "parakeet"', "", "[parakeet]", f'model = "{path or model}"']
    if streaming_capable(model):
        lines.append("streaming = true")
        lines += [f"{k} = {v}" for k, v in STREAMING_CONTEXT_SECS.items()]
    return "\n".join(lines) + "\n"


# The nemotron model the tuner's Nix wrapper provisions and pins by store path
# (VOXTYPE_NEMOTRON_MODEL). Used as the [nemotron] model value only as a
# fallback when no path is handed in. A bare checkout without the env then
# emits a resolvable registry name, so voxtype reports its own "model not found"
# rather than a nonsense `model = "None"` config.
DEFAULT_NEMOTRON_MODEL = "nemotron-3.5-asr-streaming-0.6b"


def nemotron_config_toml(
    model_path: str, target_lang: str = "auto", streaming: bool = False
) -> str:
    """Render the minimal ``[nemotron]`` config that selects ``model_path``.

    Nemotron is mandatory-config like parakeet: voxtype hard-fails ("Nemotron
    engine selected but [nemotron] config section is missing") when the engine
    is chosen without this section, and the top-level ``--model`` flag is
    whisper-only (it WARNs and drops any other name), so the model MUST arrive
    here. ``model_path`` is the absolute model directory (the five-file ONNX
    export whose ``encoder.onnx`` loads ``encoder.onnx.data`` by relative name,
    so all files must share one dir) or a registry name voxtype resolves under
    its models dir.

    ``target_lang`` is the multilingual model's BCP-47-ish locale key (e.g.
    ``"de-DE"``) or ``"auto"`` (the model detects the language itself). The
    tuner's nemotron language picker resolves its single-select choice through
    :func:`nemotron_target_lang`, so callers pass the mapped locale (or
    ``"auto"``) here. ``streaming`` is off for the tuner's batch
    ``transcribe <wav>`` path (the file transcriber ignores it anyway).
    """
    streaming_value = "true" if streaming else "false"
    lines = [
        'engine = "nemotron"',
        "",
        "[nemotron]",
        f'model = "{model_path}"',
        f'target_lang = "{target_lang}"',
        f"streaming = {streaming_value}",
    ]
    return "\n".join(lines) + "\n"


def models_for(engine: str) -> list[str]:
    """Return the selectable ``--model`` values for ``engine``.

    nemotron has no tuner model selection (its model is Nix-provisioned and
    pinned by store path, not chosen here), so it returns an empty list. An
    unknown engine also returns an empty list rather than raising, so the UI
    can degrade gracefully.
    """
    if engine == "whisper":
        return list(_WHISPER_MODELS)
    if engine == "parakeet":
        return list(_PARAKEET_MODELS)
    return []


@dataclass
class TranscribeParams:
    engine: str
    model: str
    language: str
    initial_prompt: str
    vad: bool
    vad_threshold: float
    max_duration: int
    # parakeet's cache-aware streaming daemon toggle (``parakeet.streaming``).
    # Only ever true for a streaming-capable parakeet model. The seeder clamps
    # it and the UI gate keeps it unrepresentable otherwise, so the hard-fail
    # "streaming on + incompatible model" combo the daemon refuses is never
    # constructed. Trailing default keeps every positional constructor valid.
    streaming: bool = False
    # voxtype's ``[audio] device``: the recording input the daemon (and a live
    # Stream session) captures with, and the value Record's own capture maps to
    # a PortAudio index through. A case-insensitive substring of the cpal device
    # name, or "default" for the system default (also the empty-normalized
    # value). The tuner's batch ``transcribe <wav>`` ignores it. Trailing
    # default keeps every positional constructor valid.
    device: str = "default"


def build_argv(
    p: TranscribeParams,
    wav_path: str,
    voxtype_bin: str = "voxtype",
    config_path: str | None = None,
) -> list[str]:
    """Build the voxtype invocation for ``p`` transcribing ``wav_path``.

    Every engine runs the SAME ``voxtype`` binary (the fork's parakeet build,
    which also carries the whisper and nemotron engines). There is no separate
    per-engine binary. Global flags precede the ``transcribe`` subcommand.

    ``config_path``, when given, is passed with the root ``-c`` flag (ahead of the
    subcommand like every other global) so voxtype loads that file instead of the
    user's ``~/.config/voxtype/config.toml``. Parakeet and nemotron select their
    model EXCLUSIVELY through it (a ``[parakeet]`` / ``[nemotron]`` section), and
    whisper does too for a path-pinned model, so ``--model`` is dropped whenever a
    config is supplied, because voxtype's ``--model`` is whisper-name-only and
    WARNs+drops anything else (see :func:`parakeet_config_toml` / :func:`nemotron_config_toml`).
    """
    argv: list[str] = [voxtype_bin]

    if config_path is not None:
        argv += ["-c", config_path]

    argv += ["--engine", p.engine]

    if config_path is None:
        # --model takes a whisper model NAME only. voxtype resolves names against
        # its bundled whisper catalog. A filesystem PATH is silently ignored and
        # it falls back to base.en with NO error, and a parakeet/nemotron name is
        # WARNed about and dropped. Reaching here means whisper name-based
        # selection. Every path-pinned or ONNX-engine model travels in a
        # generated config instead (whisper/parakeet/nemotron_config_toml, routed
        # by transcribe.py), which is why a config_path suppresses the flag.
        argv += ["--model", p.model]

    argv += ["--language", p.language]

    if p.initial_prompt.strip():
        argv += ["--initial-prompt", p.initial_prompt]

    if p.vad:
        argv += ["--vad", "--vad-threshold", f"{p.vad_threshold:.2f}"]

    argv += ["--max-duration", str(p.max_duration)]

    argv += ["transcribe", wav_path]
    return argv
