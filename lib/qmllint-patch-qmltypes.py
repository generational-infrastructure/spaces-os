#!/usr/bin/env python3
"""In-place rewrites for quickshell qmltypes files.

See the comment in `lib/qmllint.nix` for the rationale; this script is
intentionally a flat list of textual rewrites against the qmltypes
files quickshell publishes so qmllint reads a corrected view without
patching the binary plugin.
"""

from __future__ import annotations

import pathlib
import re
import sys

# A locally-defined, structured `Margins` value type. The `margins`
# grouped property on PanelWindow is typed `Margins`, but that value type
# is defined in the Quickshell *core* qmltypes and qmllint won't resolve a
# value type's bare C++ name across the `depends` module boundary — so
# `margins { top: … }` reports the type unresolved and its sub-properties
# missing. `anchors` escapes this only because `Anchors` is defined locally
# in the very same window qmltypes; mirror that by defining `Margins` here
# too, `isStructured` so the grouped-property initialiser type-checks.
_ANCHORS_END = (
    '        Property { name: "bottom"; type: "bool"; index: 3; lineNumber: 17 }\n'
    "    }\n"
)
_MARGINS_COMPONENT = """    Component {
        file: "panelinterface.hpp"
        lineNumber: 12
        name: "Margins"
        accessSemantics: "value"
        isStructured: true
        Property { name: "left"; type: "int"; index: 0; lineNumber: 55 }
        Property { name: "right"; type: "int"; index: 1; lineNumber: 56 }
        Property { name: "top"; type: "int"; index: 2; lineNumber: 57 }
        Property { name: "bottom"; type: "int"; index: 3; lineNumber: 58 }
    }
"""


def patch_window(path: pathlib.Path) -> None:
    """Drop `isCreatable: false` from PanelWindowInterface and register a
    local structured `Margins` value type."""
    text = path.read_text()
    new_text = re.sub(
        r'(name: "PanelWindowInterface"[\s\S]*?)(\s*isCreatable: false\s*\n)',
        r"\1\n",
        text,
    )
    if new_text == text:
        sys.exit(f"patch_window: PanelWindowInterface.isCreatable not found in {path}")

    if 'name: "Margins"' not in new_text:
        if _ANCHORS_END not in new_text:
            sys.exit(f"patch_window: Anchors anchor for Margins not found in {path}")
        new_text = new_text.replace(_ANCHORS_END, _ANCHORS_END + _MARGINS_COMPONENT, 1)

    path.write_text(new_text)


def patch_io(path: pathlib.Path) -> None:
    """Rewrite three property/parameter types in Quickshell.Io qmltypes."""
    text = path.read_text()
    rewrites = [
        # FileView.adapter resolves through the C++ class name.
        ('type: "FileViewAdapter"', 'type: "qs::io::FileViewAdapter"'),
        # Process.exited / Method.onFinished parameters.
        ('type: "QProcess::ExitStatus"', 'type: "int"'),
        # Socket.error / Method.onSocketError parameters.
        ('type: "QLocalSocket::LocalSocketError"', 'type: "int"'),
    ]
    for needle, replacement in rewrites:
        if needle not in text:
            sys.exit(f"patch_io: expected substring not found: {needle!r}")
        text = text.replace(needle, replacement)
    path.write_text(text)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(
            "usage: qmllint-patch-qmltypes.py <quickshell-window.qmltypes> <quickshell-io.qmltypes>"
        )
    patch_window(pathlib.Path(sys.argv[1]))
    patch_io(pathlib.Path(sys.argv[2]))


if __name__ == "__main__":
    main()
