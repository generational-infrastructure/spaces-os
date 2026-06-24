# Strict qmllint pass over every QML file under `programs/pi-chat/`.
#
# `--max-warnings 0` turns any warning into a build failure.
#
# Three import paths matter:
#   - `qs/` — quickshell's runtime convention that `import qs.Foo`
#     resolves relative to shell.qml. pi-chat ships its own qmldir per
#     module, so the source tree is staged verbatim via a symlink.
#   - Patched quickshell qmltypes — qmllint sees the patched tree
#     first, runtime quickshell is untouched. Fixes upstream qmltypes
#     registration gaps without monkey-patching the binary plugin or
#     littering source with `// qmllint disable` markers. Shared with the
#     noctalia checks via `lib/qmllint.nix`.
#   - Qt qmltypes — without these on `-I` the imports at the top of
#     every file fail and the report is just noise.
{ pkgs, ... }:

let
  src = ./../../programs/pi-chat;
  inherit (import ../../lib/qmllint.nix pkgs) quickshellShim;
in
pkgs.runCommand "pi-chat-qmllint"
  {
    nativeBuildInputs = [ pkgs.qt6.qtdeclarative ];
    inherit src;
    qsModules = quickshellShim;
    qtModules = "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml";
    qtWebsockets = "${pkgs.qt6.qtwebsockets}/lib/qt-6/qml";
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
      -I "$qtWebsockets" \
      --max-warnings 0 \
      "''${files[@]}"

    touch "$out"
  ''
