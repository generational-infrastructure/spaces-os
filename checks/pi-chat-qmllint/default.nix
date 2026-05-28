# Strict qmllint pass over every QML file under `programs/pi-chat/`.
#
# `--max-warnings 0` turns any warning into a build failure.
#
# Three import paths matter:
#   - `qs/` — quickshell's runtime convention that `import qs.Foo`
#     resolves relative to shell.qml. Staged via a symlink so the
#     same import works under qmllint.
#   - Patched quickshell qmltypes — qmllint sees the patched tree
#     first, runtime quickshell is untouched. Fixes upstream qmltypes
#     registration gaps without monkey-patching the binary plugin or
#     littering source with `// qmllint disable` markers.
#   - Qt qmltypes — without these on `-I` the imports at the top of
#     every file fail and the report is just noise.
{ pkgs, ... }:

let
  src = ./../../programs/pi-chat;

  # Quickshell ships qmltypes with three registration gaps that trip
  # qmllint but have no runtime effect. We mirror its `lib/qt-6/qml`
  # tree, rewrite three qmltypes files, and hand qmllint the patched
  # copy. The real `pkgs.quickshell` shared library that the panel
  # loads at runtime is unaffected.
  #
  # Patches applied:
  #
  #   1. `Quickshell._Window/PanelWindow` is declared `isCreatable:
  #      false` because the engine swaps in a Wayland/X11 subclass at
  #      runtime. qmllint takes the flag at face value and refuses to
  #      instantiate `PanelWindow { … }`. Drop the flag.
  #
  #   2. `Quickshell.Io/FileView.adapter` is typed as `FileViewAdapter`
  #      (a bare name) but the C++ class is registered as
  #      `qs::io::FileViewAdapter`. qmllint's lookup is case-sensitive
  #      on the C++ name. Rewrite the property type to the qualified
  #      form so it resolves.
  #
  #   3. `Process.exited` and `Socket.error` declare parameter types
  #      `QProcess::ExitStatus` / `QLocalSocket::LocalSocketError`.
  #      These Qt enum types are never registered with the QML engine
  #      (they're plain `Q_ENUM` on the underlying QObject, not
  #      `Q_ENUM_NS` exposed to QML). qmllint refuses to compile the
  #      signal handlers as a result. Demote the parameter types to
  #      plain `int` — the JS handler boxes everything into a Value
  #      anyway, so neither runtime nor lint loses information.
  patchedQuickshellQml =
    pkgs.runCommand "quickshell-qmllint-shim"
      {
        qs = pkgs.quickshell;
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        cp -r "$qs/lib/qt-6/qml" "$out"
        chmod -R u+w "$out"

        python3 ${./patch-qmltypes.py} \
          "$out/Quickshell/_Window/quickshell-window.qmltypes" \
          "$out/Quickshell/Io/quickshell-io.qmltypes"
      '';
in
pkgs.runCommand "pi-chat-qmllint"
  {
    nativeBuildInputs = [ pkgs.qt6.qtdeclarative ];
    inherit src;
    qsModules = patchedQuickshellQml;
    qtModules = "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml";
  }
  ''
    set -euo pipefail

    workdir=$(mktemp -d)
    ln -s "$src" "$workdir/qs"

    files=( "$src"/*.qml "$src"/Widgets/*.qml "$src"/Commons/*.qml )

    qmllint \
      -I "$workdir" \
      -I "$qsModules" \
      -I "$qtModules" \
      --max-warnings 0 \
      "''${files[@]}"

    touch "$out"
  ''
