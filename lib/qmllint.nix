# Shared tooling for the strict (`--max-warnings 0`) qmllint checks.
#
# Imported by each per-tree check (`checks/*-qmllint`) as
# `import ../../lib/qmllint.nix pkgs` so the quickshell qmltypes shim
# isn't copy-pasted. Two reusable pieces:
#
#   quickshellShim  — quickshell's qml tree with the qmltypes
#                     registration gaps qmllint trips over rewritten out
#                     (the real runtime plugin is untouched).
#   mkQsImports     — a `qs/` import root synthesised from an upstream
#                     QML tree that ships no qmldir (noctalia-shell), so
#                     `import qs.Foo` resolves under qmllint.
#
# See ./qmllint-patch-qmltypes.py and ./qmllint-gen-qmldir.py for the
# per-file rationale.
pkgs: {
  # Quickshell ships qmltypes with a handful of registration gaps that
  # trip qmllint but have no runtime effect (PanelWindow isCreatable,
  # FileView.adapter's C++ name, the Process/Socket enum params, and the
  # Margins value-type). Mirror its `lib/qt-6/qml` tree, rewrite those,
  # and hand qmllint the patched copy; the panel still loads the real
  # `pkgs.quickshell` plugin at runtime.
  quickshellShim =
    pkgs.runCommand "quickshell-qmllint-shim"
      {
        qs = pkgs.quickshell;
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        cp -r "$qs/lib/qt-6/qml" "$out"
        chmod -R u+w "$out"

        python3 ${./qmllint-patch-qmltypes.py} \
          "$out/Quickshell/_Window/quickshell-window.qmltypes" \
          "$out/Quickshell/Io/quickshell-io.qmltypes"
      '';

  # quickshell builds its `qs.*` module graph at runtime, so trees like
  # noctalia-shell's ship no on-disk qmldir; qmllint resolves a dotted
  # import only through a qmldir. Mirror `tree` as `qs/` (the leaves are
  # symlinks into the store — only the synthesised qmldir files are new)
  # and generate one qmldir per component directory so every `import
  # qs.Foo` the linted files reach, directly or transitively, resolves.
  # The mirrored tree is only on `-I` for resolution: qmllint reports
  # warnings solely for the files passed on its command line.
  mkQsImports =
    { name, tree }:
    pkgs.runCommand "qmllint-qs-imports-${name}" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      mkdir -p "$out"
      cp -rs "${tree}" "$out/qs"
      chmod -R u+w "$out/qs"
      python3 ${./qmllint-gen-qmldir.py} "$out/qs"
    '';
}
