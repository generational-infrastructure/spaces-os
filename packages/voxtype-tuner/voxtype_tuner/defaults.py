"""Seed the tuner's parameter defaults from the system voxtype config.

The NixOS module ships its generated config as ``/etc/xdg/voxtype/config.toml``
purely so this tuner can read it back as "what the system runs with"
(``$VOXTYPE_TUNER_DEFAULT_CONFIG`` overrides the location, mainly for tests).
Three outcomes, each surfaced verbatim in the status bar:

- loaded: params seeded from the file. Keys the file omits fall back
  per-key to *voxtype's* built-in defaults, because that is what the daemon
  actually runs with for that file. Notably an absent ``[vad]`` table means
  VAD off (the module omits it when disabled), not the tuner's usual "on".
- not found: no file anywhere in the chain, falling back to the tuner's own built-ins.
- unreadable: the file exists but cannot be parsed. tomllib recovers nothing
  partial from a broken file, so the fallback is the whole built-in set.

Pure logic end to end (no slint import): resolution, parsing, catalog
seeding and the modified-vs-default diff are all unit-testable.
"""

from __future__ import annotations

import os
import re
import tomllib
from bisect import insort
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import TYPE_CHECKING

from voxtype_tuner import params
from voxtype_tuner.params import TranscribeParams

if TYPE_CHECKING:
    from collections.abc import Mapping

ENV_VAR = "VOXTYPE_TUNER_DEFAULT_CONFIG"
SYSTEM_CONFIG_PATH = "/etc/xdg/voxtype/config.toml"

# What the tuner offered before system seeding existed: the catalogs' own
# defaults (engine/model/language index 0, threshold "0.40", 60s, VAD on).
BUILTIN_DEFAULTS = TranscribeParams(
    engine="whisper",
    model="tiny",
    language="en",
    initial_prompt="",
    vad=True,
    vad_threshold=0.4,
    max_duration=60,
    streaming=False,
    device="default",
)

# voxtype's own compiled-in defaults (src/config/{whisper,vad,audio}.rs and
# engines/parakeet.rs at the flake-pinned rev), the per-key fallback for a
# file that loaded but omits a key.
_VOXTYPE_FALLBACK = TranscribeParams(
    engine="whisper",
    model="base.en",
    language="en",
    initial_prompt="",
    vad=False,
    vad_threshold=0.5,
    max_duration=60,
    streaming=False,
    device="default",
)
_VOXTYPE_PARAKEET_MODEL = "parakeet-tdt-0.6b-v3"

# The module references whisper models by fetchurl store path. The store hash
# prefixes the file name itself (/nix/store/<hash>-ggml-<name>.bin), so match
# the trailing ggml-<catalog-name>.bin segment, not the whole basename.
_GGML_BASENAME = re.compile(r"ggml-(.+)\.bin$")


@dataclass(frozen=True)
class SystemDefaults:
    """The seeded defaults plus how they were obtained (for the status bar).

    ``model_paths`` maps (engine, catalog name) to the absolute path the config
    provisions that model at: the whisper fetchurl store file, a parakeet
    store dir. It feeds the availability probe and the transcribe path
    override. A config that references models by plain name contributes
    nothing (there are no bytes of its own to point at).
    """

    params: TranscribeParams
    loaded: bool
    status: str
    model_paths: Mapping[tuple[str, str], str] = field(default_factory=dict)
    # The raw parsed baseline table, kept so Apply can lay the tuner's modeled
    # keys over it and preserve every other key verbatim (hotkey/osd/output
    # safety flags the module pins). ``None`` when nothing loaded, since there is
    # then no baseline to preserve, only voxtype's built-in defaults.
    raw: Mapping[str, object] | None = None


@dataclass(frozen=True)
class SeededControls:
    """Catalogs and selections ready to push into the UI's combos.

    Off-catalog defaults are representable, not dropped: a name-like value
    (model, language) is appended verbatim, a numeric one (threshold,
    duration) is inserted keeping the catalog's numeric order.
    """

    engines: list[str]
    engine_index: int
    models: list[str]
    model_index: int
    # The language popup's checkbox rows and their states. Auto (whisper's
    # unconstrained detection) is a mode, not a row: it is on exactly when no
    # row is checked, so the pair can never encode an invalid selection.
    languages: list[str]
    language_auto: bool
    language_checked: list[bool]
    vad_thresholds: list[str]
    vad_threshold_index: int
    max_durations: list[str]
    max_duration_index: int
    vad: bool
    prompt: str
    # The parakeet streaming toggle, already clamped to a capable selection by
    # the seeder. The UI gate keeps it that way as the selection changes.
    streaming: bool


def load_defaults(
    environ: Mapping[str, str] | None = None,
    system_path: str = SYSTEM_CONFIG_PATH,
) -> SystemDefaults:
    """Resolve and parse the system config into seeded defaults.

    ``$VOXTYPE_TUNER_DEFAULT_CONFIG``, when set, is authoritative: a missing
    override reads as "not found" rather than silently falling through to
    ``system_path``, so a typo'd test fixture can't pick up host state.
    """
    env = os.environ if environ is None else environ
    path = env.get(ENV_VAR) or system_path
    if not Path(path).exists():
        return SystemDefaults(
            params=BUILTIN_DEFAULTS,
            loaded=False,
            status="System defaults: not found, using built-ins",
        )
    try:
        with Path(path).open("rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return SystemDefaults(
            params=BUILTIN_DEFAULTS,
            loaded=False,
            status="System defaults: unreadable, using built-ins",
        )
    return SystemDefaults(
        params=_params_from_toml(data),
        loaded=True,
        status=f"System defaults: {path}",
        model_paths=_model_paths(data),
        raw=data,
    )


def _table(data: Mapping[str, object], key: str) -> Mapping[str, object]:
    value = data.get(key)
    return value if isinstance(value, dict) else {}


def _str(table: Mapping[str, object], key: str, fallback: str) -> str:
    value = table.get(key)
    return value if isinstance(value, str) else fallback


def _bool(table: Mapping[str, object], key: str, fallback: bool) -> bool:
    value = table.get(key)
    return value if isinstance(value, bool) else fallback


def _int(table: Mapping[str, object], key: str, fallback: int) -> int:
    value = table.get(key)
    # bool is an int subclass: `max_duration_secs = true` must not seed 1s.
    return value if isinstance(value, int) and not isinstance(value, bool) else fallback


def _float(table: Mapping[str, object], key: str, fallback: float) -> float:
    value = table.get(key)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return fallback


def _whisper_model_name(raw: str) -> str:
    """Map the module's store-path model reference back to its catalog name.

    ``/nix/store/…-ggml-small.bin`` → ``small`` when that name is in the
    whisper catalog. Anything else (unknown basename, off-catalog name) is
    kept verbatim so the UI can show exactly what the system points at.
    """
    catalog = params.models_for("whisper")
    if raw in catalog:
        return raw
    match = _GGML_BASENAME.search(Path(raw).name)
    if match and match.group(1) in catalog:
        return match.group(1)
    return raw


def _parakeet_model_name(raw: str) -> str:
    """Map an absolute parakeet model directory back to its catalog id.

    Mirrors :func:`_whisper_model_name` for the directory-shaped engine: a
    basename that is (or, hash-prefixed like ``/nix/store/<hash>-<id>``, ends
    with) a catalog id maps to that id. Anything else is kept verbatim so the
    UI shows exactly what the config points at. No id is a dash-suffix of
    another (``…-v3`` does not tail-match ``…-v3-int8``), so the suffix probe
    is unambiguous.
    """
    catalog = params.models_for("parakeet")
    if raw in catalog:
        return raw
    base = Path(raw).name
    if base in catalog:
        return base
    for name in catalog:
        if base.endswith(f"-{name}"):
            return name
    return raw


def _model_paths(data: Mapping[str, object]) -> dict[tuple[str, str], str]:
    """Extract (engine, catalog name) -> absolute path from a parsed config.

    Only absolute model values contribute. A plain name provisions nothing.
    Both engine tables are read regardless of the selected engine, since the
    module's generated file carries the upstream-merged [whisper] block even
    for a parakeet system.
    """
    paths: dict[tuple[str, str], str] = {}
    raw = _str(_table(data, "whisper"), "model", "")
    if Path(raw).is_absolute():
        paths[("whisper", _whisper_model_name(raw))] = raw
    raw = _str(_table(data, "parakeet"), "model", "")
    if Path(raw).is_absolute():
        paths[("parakeet", _parakeet_model_name(raw))] = raw
    return paths


def _language(value: object) -> str:
    """Normalize ``whisper.language`` to the tuner's serialized form.

    voxtype's LanguageConfig is a string (``"en"`` / ``"auto"``) or an array
    (``["en", "de"]`` = constrained auto-detect). The CLI takes the same set
    comma-separated. Both shapes land here as one canonical string: members in
    catalog order first, off-catalog codes sorted after, exactly the order
    the popup checklist serializes in, so an untouched UI round-trips equal
    and the modified indicator stays honest.
    """
    if isinstance(value, str):
        entries = [c.strip() for c in value.split(",") if c.strip()]
    elif isinstance(value, list):
        entries = [e.strip() for e in value if isinstance(e, str) and e.strip()]
    else:
        entries = []
    if not entries:
        return _VOXTYPE_FALLBACK.language
    if params.AUTO_LANGUAGE in entries:
        # Constraining detection to a set that names "auto" is contradictory.
        # It means unconstrained, which is also all the checklist can show.
        return params.AUTO_LANGUAGE
    members = [c for c in params.LANGUAGES if c in entries]
    extras = sorted(set(entries) - set(params.LANGUAGES))
    return ",".join([*members, *extras])


def _params_from_toml(data: Mapping[str, object]) -> TranscribeParams:
    engine = _str(data, "engine", _VOXTYPE_FALLBACK.engine)
    if engine not in ("whisper", "parakeet", "nemotron"):
        engine = _VOXTYPE_FALLBACK.engine
    whisper = _table(data, "whisper")
    vad = _table(data, "vad")
    audio = _table(data, "audio")

    # language seeds from the merged [whisper] block for whisper/parakeet, but
    # nemotron has its own single-target [nemotron].target_lang locale. Seed the
    # picker by reverse-mapping that back to a curated code (unknown/auto → Auto),
    # so the round-trip and modified-dot stay honest for the nemotron engine.
    language = _language(whisper.get("language"))

    if engine == "parakeet":
        parakeet = _table(data, "parakeet")
        model = _parakeet_model_name(_str(parakeet, "model", _VOXTYPE_PARAKEET_MODEL))
        streaming_raw = _bool(parakeet, "streaming", _VOXTYPE_FALLBACK.streaming)
    elif engine == "nemotron":
        # Nemotron has no tuner model catalog (its model is Nix-provisioned and
        # pinned by store path, not chosen here), so the model combo stays
        # empty/disabled, seeding an empty selection rather than a store path the
        # UI would surface as a bogus selectable row.
        model = ""
        nemotron = _table(data, "nemotron")
        streaming_raw = _bool(nemotron, "streaming", _VOXTYPE_FALLBACK.streaming)
        language = params.nemotron_language_from_target(
            _str(nemotron, "target_lang", params.AUTO_LANGUAGE)
        )
    else:
        model = _whisper_model_name(_str(whisper, "model", _VOXTYPE_FALLBACK.model))
        streaming_raw = False

    # Streaming is only honored by the engines/models that can stream: clamp
    # here (the shared engine_can_stream predicate) so a hand-edited "streaming
    # on + wrong model" (the combo the daemon refuses to start on) never seeds
    # an invalid baseline the UI would then serialize back verbatim. Nemotron's
    # one model always streams, while whisper never does.
    streaming = params.engine_can_stream(engine, model) and streaming_raw

    return TranscribeParams(
        engine=engine,
        model=model,
        # whisper/parakeet take language from the upstream-merged [whisper] block,
        # while nemotron's came from [nemotron].target_lang above. initial_prompt seeds
        # from [whisper] for every engine (whisper-only, ignored elsewhere).
        language=language,
        initial_prompt=_str(whisper, "initial_prompt", ""),
        vad=_bool(vad, "enabled", _VOXTYPE_FALLBACK.vad),
        # The threshold combo shows two decimals. Round so "unmodified"
        # round-trips exactly through the combo string.
        vad_threshold=round(
            _float(vad, "threshold", _VOXTYPE_FALLBACK.vad_threshold), 2
        ),
        max_duration=_int(audio, "max_duration_secs", _VOXTYPE_FALLBACK.max_duration),
        streaming=streaming,
        # voxtype normalizes an empty device to the system default, so seed the
        # same way: an absent or blank [audio].device reads as "default", and
        # the picker reverse-maps that to the System-default row.
        device=_str(audio, "device", _VOXTYPE_FALLBACK.device)
        or _VOXTYPE_FALLBACK.device,
    )


def user_config_path(environ: Mapping[str, str] | None = None) -> str:
    """The user's effective voxtype config path.

    ``$XDG_CONFIG_HOME/voxtype/config.toml`` when set to an absolute path
    (matching the Rust ``directories`` crate and models.py's data-dir probe),
    else the ``~/.config`` fallback, the exact file the module's daemon
    wrapper prefers over the generated config.
    """
    env = os.environ if environ is None else environ
    xdg = env.get("XDG_CONFIG_HOME")
    if xdg and Path(xdg).is_absolute():
        base = Path(xdg)
    else:
        base = Path("~").expanduser() / ".config"
    return str(base / "voxtype" / "config.toml")


@dataclass(frozen=True)
class StartupDefaults:
    """Everything configure() needs at startup: the two layers plus status.

    ``system`` is the BASELINE, what the modified indicators compare against
    and what Reset restores. ``initial`` is what the controls start at: the
    user's effective config when one exists, else the baseline.

    ``model_paths`` is the union of both layers' absolute model references
    (see :class:`SystemDefaults`). A system entry wins a per-model conflict,
    since the system layer is what the tuner reports as "system".
    """

    system: SystemDefaults
    initial: TranscribeParams
    status: str
    model_paths: Mapping[tuple[str, str], str] = field(default_factory=dict)


def load_startup(
    environ: Mapping[str, str] | None = None,
    system_path: str = SYSTEM_CONFIG_PATH,
) -> StartupDefaults:
    """Resolve both layers: the baseline plus the user's effective config.

    The user override, when present, is what the daemon actually runs with
    (the module's wrapper prefers it over the generated config), and voxtype
    does NOT merge config files, an override layers over voxtype's built-in
    defaults. So the initial values come from parsing the user file with the
    same per-key voxtype fallbacks as the baseline, never from mixing the two
    files. A malformed user file follows the baseline policy: ignored
    wholesale, with its own status note.
    """
    system = load_defaults(environ=environ, system_path=system_path)
    path = user_config_path(environ)
    if not Path(path).exists():
        return StartupDefaults(
            system=system,
            initial=system.params,
            status=system.status,
            model_paths=system.model_paths,
        )
    try:
        with Path(path).open("rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return StartupDefaults(
            system=system,
            initial=system.params,
            status=f"User config: unreadable, using system defaults · {system.status}",
            model_paths=system.model_paths,
        )
    return StartupDefaults(
        system=system,
        initial=_params_from_toml(data),
        status=f"User config: {path} · {system.status}",
        model_paths={**_model_paths(data), **system.model_paths},
    )


def model_catalog_for(
    engine: str,
    defaults: TranscribeParams,
    also: TranscribeParams | None = None,
) -> tuple[list[str], int]:
    """The model combo's entries and default selection for ``engine``.

    Used both at seeding and on every engine switch, so flipping engines away
    and back always restores the same catalog (custom entry included) and
    re-selects the system default rather than whatever sits at index 0.
    ``also`` contributes its off-catalog model too (sorted, so the catalog is
    identical whichever of the two param sets is selected). This keeps the
    user's custom model and the baseline's both selectable from one list.
    """
    catalog = params.models_for(engine)
    custom = sorted(
        {
            p.model
            for p in (defaults, also)
            # ``p.model`` truthiness guard keeps nemotron's empty selection from
            # becoming a blank catalog row (its combo must stay empty/disabled).
            if p is not None
            and p.engine == engine
            and p.model
            and p.model not in catalog
        }
    )
    catalog = [*catalog, *custom]
    # A default whose model isn't in the catalog (a foreign engine, or
    # nemotron's empty model) selects index 0 rather than raising on .index().
    if engine != defaults.engine or defaults.model not in catalog:
        return catalog, 0
    return catalog, catalog.index(defaults.model)


def seed_controls(
    defaults: TranscribeParams, also: TranscribeParams | None = None
) -> SeededControls:
    """Resolve ``defaults`` into combo catalogs plus their selected indices.

    ``also`` contributes a second param set's off-catalog values (custom
    entries sorted, numeric entries in numeric order) without affecting the
    selection, so seeding the initial (user) values and resetting to the
    baseline share one stable catalog. Only the indices differ.
    """
    both = [defaults] if also is None else [defaults, also]
    models, model_index = model_catalog_for(defaults.engine, defaults, also)

    # Every member of either constrained set must be a row (or it could never
    # be re-checked). Off-catalog codes sort after the catalog, matching the
    # canonical order _language() seeds so selections round-trip verbatim.
    languages = list(params.LANGUAGES)
    languages += sorted(
        {c for p in both for c in params.language_codes(p.language)} - set(languages)
    )
    selected = set(params.language_codes(defaults.language))

    thresholds = list(params.VAD_THRESHOLDS)
    for label in sorted({f"{p.vad_threshold:.2f}" for p in both}):
        if label not in thresholds:
            insort(thresholds, label, key=float)
    threshold_label = f"{defaults.vad_threshold:.2f}"

    durations = [str(d) for d in params.MAX_DURATIONS]
    for label in sorted({str(p.max_duration) for p in both}):
        if label not in durations:
            insort(durations, label, key=int)
    duration_label = str(defaults.max_duration)

    return SeededControls(
        engines=list(params.ENGINES),
        engine_index=params.ENGINES.index(defaults.engine),
        models=models,
        model_index=model_index,
        languages=languages,
        language_auto=not selected,
        language_checked=[code in selected for code in languages],
        vad_thresholds=thresholds,
        vad_threshold_index=thresholds.index(threshold_label),
        max_durations=durations,
        max_duration_index=durations.index(duration_label),
        vad=defaults.vad,
        prompt=defaults.initial_prompt,
        streaming=defaults.streaming,
    )


def modified_fields(
    current: TranscribeParams, defaults: TranscribeParams
) -> frozenset[str]:
    """Names of the params where ``current`` differs from the seeded default."""
    return frozenset(
        f.name
        for f in fields(TranscribeParams)
        if getattr(current, f.name) != getattr(defaults, f.name)
    )
