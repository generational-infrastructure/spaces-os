"""Serialize the effective config and apply it by restarting the user daemon.

The tuner's Apply writes ``$XDG_CONFIG_HOME/voxtype/config.toml`` and restarts
the per-user ``voxtype`` unit. Two facts about voxtype shape everything here:

- voxtype does NOT merge config files. A ``-c``/user config layers over
  voxtype's compiled-in DEFAULTS, never over the system file. So an override
  the tuner writes must be COMPLETE. Every key the daemon should keep has to
  be present, or it silently reverts to a built-in (hotkey back on, OSD back
  on, notifications back on: exactly the settings the NixOS module pins off).
- voxtype has no ``deny_unknown_fields`` anywhere (verified against the 0.7.5
  source), so preserving keys the tuner does not model is free. An unknown
  key is silently ignored, never a startup failure.

The strategy therefore is preservation, not regeneration: start from the parsed
system baseline (``/etc/xdg/voxtype/config.toml``), lay the tuner's modeled keys
on top, and emit every other key verbatim. When there is no baseline (no system
config), only the modeled keys are written. There is nothing else to preserve,
and the daemon fills the rest from its built-ins.

Pure end to end except :func:`apply_config`/:func:`revert_config`, which touch
the filesystem and shell out to ``systemctl``. Both the target path and the
``systemctl`` binary are injectable so tests and MCP runs never restart the
real daemon.
"""

from __future__ import annotations

import contextlib
import copy
import os
import subprocess
import tempfile
from dataclasses import dataclass, fields
from pathlib import Path
from typing import TYPE_CHECKING, Literal

from voxtype_tuner import models, params
from voxtype_tuner.params import STREAMING_CONTEXT_SECS, TranscribeParams

if TYPE_CHECKING:
    from collections.abc import Mapping

# Overriding this points the restart at a fake ``systemctl`` (tests, MCP runs).
# Unset, the real user daemon is restarted.
SYSTEMCTL_ENV = "VOXTYPE_TUNER_SYSTEMCTL"

# How long to wait on the restart before declaring it wedged. A restart is a
# stop+start of a local unit. 30s is generous headroom for model reload.
_RESTART_TIMEOUT_S = 30.0


def default_systemctl() -> str:
    """The ``systemctl`` binary to drive, honoring the test/MCP override."""
    return os.environ.get(SYSTEMCTL_ENV, "systemctl")


def resolve_model_value(
    engine: str,
    model: str,
    model_paths: Mapping[tuple[str, str], str] | None = None,
    nemotron_model: str | None = None,
) -> str:
    """The string the daemon config must carry for ``(engine, model)``.

    Mirrors the transcribe path's rule exactly: a ``system``-availability model
    lives only at its config-provided absolute path (voxtype's name lookup
    searches the user dir alone), so write that path. A ``user`` download and an
    ``absent`` selection both resolve by NAME, so write the catalog name. An
    already-absolute ``model`` stays itself either way.

    Nemotron is special-cased: it has no tuner model catalog (``model`` is
    always empty) and its availability always probes ``absent``, so its model
    can only be the caller-supplied ``nemotron_model`` (the env/Nix-provisioned
    store dir), falling back to the resolvable default registry name.
    """
    if engine == "nemotron":
        return nemotron_model or params.DEFAULT_NEMOTRON_MODEL
    avail = models.model_availability(engine, model, model_paths)
    return avail.path if avail.state == "system" and avail.path else model


def _ensure_table(data: dict[str, object], key: str) -> dict[str, object]:
    """Return ``data[key]`` as a table, replacing a missing/non-table value.

    tomllib always parses a table as a dict, so the replacement path only fires
    for a hand-mangled baseline. Either way the caller gets a real dict to
    mutate without corrupting sibling keys.
    """
    value = data.get(key)
    if not isinstance(value, dict):
        value = {}
        data[key] = value
    return value


def _language_value(language: str) -> str | list[str]:
    """Serialize a language selection into voxtype's ``LanguageConfig`` shape.

    voxtype's ``language`` is an untagged enum: a bare string for a single code
    or ``auto``, an ARRAY for a constrained multi-code set (a comma string would
    deserialize as one bogus code). The tuner carries the set comma-joined, so
    split it back to the array the daemon actually round-trips.
    """
    codes = params.language_codes(language)
    if len(codes) > 1:
        return codes
    return language


def build_config(
    p: TranscribeParams,
    baseline: Mapping[str, object] | None,
    model_value: str,
) -> dict[str, object]:
    """The complete config table for ``p``, preserving ``baseline`` verbatim.

    ``model_value`` is the pre-resolved model string (see
    :func:`resolve_model_value`). Passing it in keeps this function pure and
    filesystem-free. Only the keys the tuner models are touched. A table is
    read/written for the selected engine while the other engine's table (and
    every unmodeled key: hotkey, osd, output, audio device/rate, whisper
    translate/on_demand_loading, …) is left exactly as the baseline had it.
    """
    data: dict[str, object] = copy.deepcopy(dict(baseline)) if baseline else {}

    data["engine"] = p.engine

    # initial_prompt seeds from [whisper] for BOTH engines, mirroring the loader,
    # so it is written to [whisper] regardless of engine. language does too for
    # whisper/parakeet, but nemotron carries its own single-target
    # [nemotron].target_lang instead, so its picker value must NOT clobber the
    # preserved [whisper].language (a user's whisper language survives an Apply
    # made while nemotron is selected).
    whisper = _ensure_table(data, "whisper")
    if p.engine != "nemotron":
        whisper["language"] = _language_value(p.language)
    if p.initial_prompt.strip():
        whisper["initial_prompt"] = p.initial_prompt
    else:
        # An empty prompt is no prompt: drop the key rather than write "" so a
        # parakeet baseline (which never carries initial_prompt) round-trips.
        whisper.pop("initial_prompt", None)

    if p.engine == "whisper":
        whisper["model"] = model_value
    elif p.engine == "parakeet":
        parakeet = _ensure_table(data, "parakeet")
        parakeet["model"] = model_value
        parakeet["streaming"] = p.streaming
        if p.streaming:
            # The capable model refuses to load without the blessed context
            # profile. Force it so turning streaming on always yields a
            # loadable config even if the baseline had no context keys.
            parakeet.update(STREAMING_CONTEXT_SECS)
    elif p.engine == "nemotron":
        nemotron = _ensure_table(data, "nemotron")
        # Nemotron streaming is JUST the boolean. It takes NONE of parakeet's
        # mel-frame context keys, and emitting them would make voxtype reject
        # the config. Write only the flag.
        nemotron["streaming"] = p.streaming
        # voxtype hard-fails ("[nemotron] config section is missing") without a
        # model. Preserve the baseline's verbatim when present (a nemotron
        # system pins the store dir). Otherwise pin the provisioned/default one
        # so an Apply over a non-nemotron baseline still yields a loadable
        # config.
        if not nemotron.get("model"):
            nemotron["model"] = model_value
        # Write the SELECTED language as nemotron's own target_lang locale (its
        # single-target BCP-47-ish key, Auto/unknown → "auto"), replacing the
        # baseline's. This is where the picker's choice actually reaches the
        # daemon, so it must reflect the current selection, not merely default.
        nemotron["target_lang"] = params.nemotron_target_lang(p.language)

    vad = _ensure_table(data, "vad")
    # Explicit true/false: the module omits [vad] when disabled, so an explicit
    # flag is the only unambiguous, round-trippable way to say "VAD off".
    vad["enabled"] = p.vad
    vad["threshold"] = round(p.vad_threshold, 2)

    audio = _ensure_table(data, "audio")
    audio["max_duration_secs"] = p.max_duration
    # The recording input the daemon (and a live Stream session) captures with.
    # Written beside the preserved [audio] block. An empty selection normalizes
    # to voxtype's "default", so the key is always a resolvable value.
    audio["device"] = p.device or "default"

    return data


def serialize_config(
    p: TranscribeParams,
    baseline: Mapping[str, object] | None,
    model_value: str,
) -> str:
    """Render the complete override config for ``p`` as TOML text."""
    return _dump_toml(build_config(p, baseline, model_value))


# --- what-will-change preview -------------------------------------------------

_FIELD_LABELS: dict[str, str] = {
    "engine": "Engine",
    "model": "Model",
    "language": "Language",
    "initial_prompt": "Prompt",
    "vad": "VAD",
    "vad_threshold": "Threshold",
    "max_duration": "Max duration",
    "streaming": "Streaming",
    "device": "Device",
}


@dataclass(frozen=True)
class ConfigChange:
    """One line of the Apply preview: a param that differs from the effective
    config, with its current-vs-new human-readable values.
    """

    label: str
    old: str
    new: str

    def line(self) -> str:
        return f"{self.label}: {self.old} → {self.new}"


def _fmt(name: str, value: object) -> str:
    if name in ("vad", "streaming"):
        return "on" if value else "off"
    if name == "vad_threshold" and isinstance(value, (int, float)):
        return f"{value:.2f}"
    if name == "max_duration":
        return f"{value}s"
    if name == "initial_prompt":
        return f'"{value}"' if value else "(none)"
    if name == "model":
        return str(value) if value else "(none)"
    if name == "device":
        return "system default" if value == "default" else str(value)
    return str(value)


def config_changes(
    current: TranscribeParams, effective: TranscribeParams
) -> list[ConfigChange]:
    """The per-param diff of ``current`` against the EFFECTIVE config.

    "Effective" is what the daemon runs right now: the user override when one
    exists, else the system baseline. Diffing against it (not the system
    baseline the modified-dots use) makes the preview and the "nothing to apply"
    gate reflect the real change the restart would introduce. Dataclass field
    order gives a stable line order.
    """
    changes: list[ConfigChange] = []
    for f in fields(TranscribeParams):
        cur = getattr(current, f.name)
        eff = getattr(effective, f.name)
        if cur != eff:
            changes.append(
                ConfigChange(
                    _FIELD_LABELS[f.name], _fmt(f.name, eff), _fmt(f.name, cur)
                )
            )
    return changes


# --- write + restart ----------------------------------------------------------

ApplyKind = Literal["applied", "reverted", "write_failed", "restart_failed"]


@dataclass(frozen=True)
class ApplyOutcome:
    """How an Apply/Revert ended, with a UI-ready status-bar message."""

    ok: bool
    kind: ApplyKind
    message: str


def write_config_atomic(path: str, text: str) -> None:
    """Write ``text`` to ``path`` atomically (temp file in the same dir + rename).

    An interrupted or failing write must never leave a partial config the daemon
    would then fail to parse: the content lands in full at a sibling temp file
    first, and ``os.replace`` swaps it in as one atomic step. The temp file is
    removed on any error so a failed write leaks nothing.
    """
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(
        dir=str(target.parent), prefix=".config-", suffix=".toml.tmp"
    )
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        Path(tmp).replace(target)
    except OSError:
        with contextlib.suppress(OSError):
            Path(tmp).unlink()
        raise


def restart_daemon(systemctl_bin: str) -> tuple[bool, str]:
    """Run ``systemctl --user restart voxtype``, returning ``(ok, short_reason)``.

    Never raises: a missing binary or a timeout folds into ``ok=False`` with a
    short reason for the status bar. A malformed override makes the unit fail
    (the module runs it ``Restart=on-failure`` with no silent fallback), which
    surfaces here as a nonzero restart.
    """
    try:
        proc = subprocess.run(
            [systemctl_bin, "--user", "restart", "voxtype"],
            capture_output=True,
            text=True,
            timeout=_RESTART_TIMEOUT_S,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    if proc.returncode != 0:
        reason = proc.stderr.strip().splitlines()
        return False, (reason[-1] if reason else f"systemctl exited {proc.returncode}")
    return True, ""


def apply_config(
    p: TranscribeParams,
    baseline: Mapping[str, object] | None,
    model_paths: Mapping[tuple[str, str], str] | None,
    config_path: str,
    systemctl_bin: str,
    nemotron_model: str | None = None,
) -> ApplyOutcome:
    """Serialize ``p`` over ``baseline``, write it atomically, restart the daemon.

    The write and the restart are distinct outcomes: a write failure never
    touches the daemon, and a restart failure leaves the (already written)
    override in place with a pointer to the escape hatch. Fix or remove it.

    ``nemotron_model`` is the provisioned nemotron store dir the caller reads
    from the environment. It pins ``[nemotron].model`` when the engine is
    nemotron and the baseline carried no model of its own (see
    :func:`resolve_model_value`).
    """
    model_value = resolve_model_value(
        p.engine, p.model, model_paths, nemotron_model=nemotron_model
    )
    text = serialize_config(p, baseline, model_value)
    try:
        write_config_atomic(config_path, text)
    except OSError as exc:
        return ApplyOutcome(
            ok=False,
            kind="write_failed",
            message=f"apply failed: could not write {config_path}: {exc}",
        )
    ok, reason = restart_daemon(systemctl_bin)
    if not ok:
        return ApplyOutcome(
            ok=False,
            kind="restart_failed",
            message=(
                f"wrote config, but daemon restart failed: {reason}"
                f". Fix or remove {config_path}"
            ),
        )
    return ApplyOutcome(ok=True, kind="applied", message="applied, daemon restarted")


def revert_config(config_path: str, systemctl_bin: str) -> ApplyOutcome:
    """Remove the override and restart, returning the daemon to system defaults.

    Removing a missing file is a no-op success (the daemon already runs the
    system config). The restart is still issued so the outcome is honest either
    way.
    """
    try:
        Path(config_path).unlink(missing_ok=True)
    except OSError as exc:
        return ApplyOutcome(
            ok=False,
            kind="write_failed",
            message=f"revert failed: could not remove {config_path}: {exc}",
        )
    ok, reason = restart_daemon(systemctl_bin)
    if not ok:
        return ApplyOutcome(
            ok=False,
            kind="restart_failed",
            message=f"removed config, but daemon restart failed: {reason}",
        )
    return ApplyOutcome(
        ok=True,
        kind="reverted",
        message="reverted to system defaults, daemon restarted",
    )


# --- minimal TOML emitter -----------------------------------------------------
#
# tomllib reads but cannot write, and pulling a TOML writer into the pure/offline
# nix closure is not worth one bounded config shape. This emits exactly the value
# kinds a voxtype config holds: scalars, string arrays, nested tables, and (for
# a hand-edited [[osd.visual.layers]]) arrays of tables, round-tripping every
# key tomllib parsed. Verified by parse -> dump -> parse equality in the tests.


def _dump_toml(data: Mapping[str, object]) -> str:
    out: list[str] = []
    _emit_table(data, [], out)
    # Drop a leading blank the first subtable header would otherwise add.
    while out and out[0] == "":
        out.pop(0)
    return "\n".join(out) + "\n" if out else ""


def _is_array_of_tables(value: object) -> bool:
    return (
        isinstance(value, list)
        and len(value) > 0
        and all(isinstance(v, dict) for v in value)
    )


def _emit_table(table: Mapping[str, object], path: list[str], out: list[str]) -> None:
    for key, value in table.items():
        if not isinstance(value, dict) and not _is_array_of_tables(value):
            out.append(f"{_emit_key(key)} = {_emit_value(value)}")
    for key, value in table.items():
        child = [*path, key]
        if isinstance(value, dict):
            out.append("")
            out.append(f"[{_emit_key_path(child)}]")
            _emit_table(value, child, out)
        elif isinstance(value, list) and _is_array_of_tables(value):
            for item in value:
                if isinstance(item, dict):
                    out.append("")
                    out.append(f"[[{_emit_key_path(child)}]]")
                    _emit_table(item, child, out)


_BARE_KEY_CHARS = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
)


def _emit_key(key: str) -> str:
    if key and all(ch in _BARE_KEY_CHARS for ch in key):
        return key
    return _emit_string(key)


def _emit_key_path(path: list[str]) -> str:
    return ".".join(_emit_key(k) for k in path)


def _emit_value(value: object) -> str:
    # bool BEFORE int: bool is an int subclass and must render true/false.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _emit_float(value)
    if isinstance(value, str):
        return _emit_string(value)
    if isinstance(value, dict):
        inner = ", ".join(
            f"{_emit_key(k)} = {_emit_value(v)}" for k, v in value.items()
        )
        return "{" + inner + "}"
    if isinstance(value, list):
        return "[" + ", ".join(_emit_value(v) for v in value) + "]"
    # No other type survives a tomllib parse. Be explicit rather than silent.
    msg = f"cannot serialize {type(value).__name__} to TOML"
    raise TypeError(msg)


def _emit_float(value: float) -> str:
    if value != value:  # NaN  # noqa: PLR0124
        return "nan"
    if value == float("inf"):
        return "inf"
    if value == float("-inf"):
        return "-inf"
    # repr gives the shortest round-tripping decimal. Ensure a TOML float always
    # carries a point/exponent so an integer-valued float stays a float.
    text = repr(value)
    if "." not in text and "e" not in text and "E" not in text:
        text += ".0"
    return text


_STRING_ESCAPES = {
    '"': '\\"',
    "\\": "\\\\",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
    "\b": "\\b",
    "\f": "\\f",
}

# Codepoints below the space are TOML control chars: escape them as \uXXXX.
_FIRST_PRINTABLE = 0x20


def _emit_string(value: str) -> str:
    out = ['"']
    for ch in value:
        if ch in _STRING_ESCAPES:
            out.append(_STRING_ESCAPES[ch])
        elif ord(ch) < _FIRST_PRINTABLE:
            out.append(f"\\u{ord(ch):04X}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)
