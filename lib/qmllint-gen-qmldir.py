#!/usr/bin/env python3
"""Synthesise qmldir files for a quickshell-convention QML tree.

quickshell maps `import qs.Foo.Bar` to the directory `Foo/Bar` under the
shell root and builds that module graph at runtime, so trees like
noctalia-shell's ship no on-disk qmldir. qmllint, by contrast, resolves
a dotted module import *only* through a qmldir. This walks a mirror of
the tree and writes one qmldir per directory that holds component files,
so every `qs.*` import a linted plugin reaches — directly, or
transitively through the singletons it touches — resolves statically.

A component file is any `*.qml` whose basename starts with an uppercase
letter (QML's own rule for an importable type). `pragma Singleton` marks
the file as a singleton so the qmldir entry matches how callers use it
(`Color.mError` etc.); getting that wrong makes qmllint reject the
member access.
"""

from __future__ import annotations

import pathlib
import sys


def is_singleton(qml: pathlib.Path) -> bool:
    # `pragma Singleton` sits in the file's prefix, ahead of the first
    # type; stop at the first import or real token so the word can't be
    # picked up from a comment further down.
    for line in qml.read_text(errors="replace").splitlines():
        s = line.strip()
        if s.startswith("pragma Singleton"):
            return True
        if s.startswith("import ") or (
            s and not s.startswith(("pragma", "//", "/*", "*"))
        ):
            break
    return False


def gen_dir(d: pathlib.Path, root: pathlib.Path) -> None:
    components = sorted(p for p in d.glob("*.qml") if p.name[:1].isupper())
    if not components:
        return
    rel = d.relative_to(root)
    module = ".".join(("qs", *rel.parts)) if rel.parts else "qs"
    lines = [f"module {module}", ""]
    for p in components:
        prefix = "singleton " if is_singleton(p) else ""
        lines.append(f"{prefix}{p.stem} 1.0 {p.name}")
    (d / "qmldir").write_text("\n".join(lines) + "\n")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: qmllint-gen-qmldir.py <qs-import-root>")
    root = pathlib.Path(sys.argv[1])
    for d in [root, *sorted(p for p in root.rglob("*") if p.is_dir())]:
        gen_dir(d, root)


if __name__ == "__main__":
    main()
