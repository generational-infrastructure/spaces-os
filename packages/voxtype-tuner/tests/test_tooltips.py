"""Every interactive control must carry explanatory hover help.

The tooltip strings live as ``tt-*`` out-properties in ``ui/app.slint`` (the
single source of truth): each control binds BOTH its ``accessible-description``
and a built-in ``Tooltip``'s ``TipCard`` content to the same ``tt-*`` property,
so the visible tooltip and the MCP/assistive-tech description can never
disagree. State-dependent controls (the Record/Download/Transcribe/Stream
relabels, the whisper-only / streaming gates) carry reactive ternary text.

This suite asserts that wiring at the source level rather than by instantiating
a window: a real ``MainWindow`` needs the slint-dev headless backend, which the
nix build sandbox does not ship (see ``test_lifecycle``'s ``needs_headless``),
so a runtime read would only ever *skip* in-sandbox. Parsing the compiled UI
source instead makes the "every control has non-empty hover help" guarantee run
everywhere the rest of the suite does. The reactive values themselves are
exercised live over the Slint MCP during headless verification.
"""

from __future__ import annotations

import pathlib
import re

# Resolve ui/app.slint without importing slint, so this assertion runs even in
# environments where the native lib is absent (app.py resolves it the same way,
# one dir above the package).
SLINT_FILE = pathlib.Path(__file__).resolve().parent.parent / "ui" / "app.slint"

# Every interactive control that must explain what it does, mapped to the
# out-property that is its single source of truth. Kept explicit (not derived
# from the file) so a control added without a tooltip fails loudly here.
CONTROL_TOOLTIPS: dict[str, str] = {
    "engine-combo": "tt-engine",
    "model-combo": "tt-model",
    "device-combo": "tt-device",
    "model-download": "tt-download",
    "model-download-status": "tt-model-status",
    "vad-check": "tt-vad",
    "vad-threshold-combo": "tt-vad-threshold",
    "maxdur-combo": "tt-maxdur",
    "language-pill": "tt-language",
    "prompt-input": "tt-prompt",
    "stream-param-check": "tt-streaming",
    "take-record": "tt-record",
    "take-play": "tt-play",
    "take-transcribe": "tt-transcribe",
    "take-stream": "tt-stream",
    "transcription-copy": "tt-copy",
    "transcription-clear": "tt-clear",
    "defaults-reset": "tt-reset",
    "config-apply": "tt-apply",
    "config-revert": "tt-revert",
}


def _source() -> str:
    return SLINT_FILE.read_text(encoding="utf-8")


def _tooltip_definitions(text: str) -> dict[str, str]:
    """Map each ``tt-*`` out-property to its declared value expression.

    Each value ends with a string literal, so the statement terminator is the
    first ``";`` (closing quote then semicolon). Anchoring on that, rather than
    a bare ``;``, avoids truncating at the semicolons that appear *inside* the
    sentences (e.g. "the default; Parakeet …").
    """
    return {
        name: value.strip()
        for name, value in re.findall(
            r'out property <string> (tt-[a-z-]+):(.*?");', text, re.DOTALL
        )
    }


def _string_literals(expr: str) -> list[str]:
    return re.findall(r'"([^"]*)"', expr)


def test_every_control_is_wired_to_a_tooltip_property() -> None:
    # Each control must bind BOTH its accessible-description and its Tooltip's
    # TipCard text to the same tt-* property, so the two always match.
    text = _source()
    for control_id, tt in CONTROL_TOOLTIPS.items():
        assert f"{control_id} :=" in text, f"{control_id} not found in app.slint"
        assert f"accessible-description: root.{tt};" in text, (
            f"{control_id} has no accessible-description bound to root.{tt}"
        )
        assert f"Tooltip {{ TipCard {{ text: root.{tt}; }} }}" in text, (
            f"{control_id} has no hover Tooltip bound to root.{tt}"
        )


def test_every_tooltip_property_has_nonempty_text() -> None:
    # The single-source-of-truth strings must exist and be non-empty in EVERY
    # branch. A blank relabel (e.g. an empty "Stop" variant) must fail here.
    defs = _tooltip_definitions(_source())
    expected = set(CONTROL_TOOLTIPS.values())
    assert set(defs) == expected, (
        f"tt-* properties drifted from the control list: "
        f"missing={expected - set(defs)} extra={set(defs) - expected}"
    )
    for name, value in defs.items():
        literals = _string_literals(value)
        assert literals, f"{name} declares no text"
        for literal in literals:
            assert literal.strip(), f"{name} has an empty string branch"


def test_reactive_tooltips_cover_both_states() -> None:
    # The controls that relabel or gate must carry DISTINCT text per state, so a
    # hover always explains the CURRENT state (why a control is disabled, or
    # what a Stop will do). Assert each reactive tooltip is a conditional with
    # at least two different non-empty messages.
    defs = _tooltip_definitions(_source())
    reactive = [
        "tt-download",
        "tt-language",
        "tt-streaming",
        "tt-record",
        "tt-transcribe",
        "tt-stream",
        "tt-apply",
    ]
    for name in reactive:
        value = defs[name]
        assert "?" in value, f"{name} is not a conditional"
        assert ":" in value, f"{name} is not state-dependent"
        # The comparands (e.g. "absent") are string literals too. The messages
        # are the ones with whitespace/sentence punctuation. Require at least
        # two distinct multi-word messages so both states say something real.
        messages = {lit for lit in _string_literals(value) if " " in lit.strip()}
        assert len(messages) >= 2, f"{name} lacks distinct per-state messages"
