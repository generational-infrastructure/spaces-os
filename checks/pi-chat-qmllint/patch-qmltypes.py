#!/usr/bin/env python3
"""In-place rewrites for quickshell qmltypes files.

See the comment in `default.nix` for the rationale; this script is
intentionally a flat list of textual rewrites against the qmltypes
files quickshell publishes so qmllint reads a corrected view without
patching the binary plugin.
"""

from __future__ import annotations

import pathlib
import re
import sys


def patch_window(path: pathlib.Path) -> None:
    """Drop `isCreatable: false` from PanelWindowInterface."""
    text = path.read_text()
    new_text = re.sub(
        r'(name: "PanelWindowInterface"[\s\S]*?)(\s*isCreatable: false\s*\n)',
        r"\1\n",
        text,
    )
    if new_text == text:
        sys.exit(f"patch_window: PanelWindowInterface.isCreatable not found in {path}")
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
            "usage: patch-qmltypes.py <quickshell-window.qmltypes> <quickshell-io.qmltypes>"
        )
    patch_window(pathlib.Path(sys.argv[1]))
    patch_io(pathlib.Path(sys.argv[2]))


if __name__ == "__main__":
    main()
