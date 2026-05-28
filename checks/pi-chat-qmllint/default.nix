# Strict qmllint pass over every QML file under `programs/pi-chat/`.
#
# `--max-warnings 0` turns any warning into a build failure. Cases we
# can't fix from this side are suppressed per-line with `// qmllint
# disable …` and tracked in `programs/pi-chat/QMLLINT-DEBT.md`.
#
# Two import paths matter:
#   - `qs/` — quickshell's runtime convention that `import qs.Foo`
#     resolves relative to shell.qml. Staged via a symlink so the
#     same import works under qmllint.
#   - Qt + quickshell qmltypes — without these on `-I` the imports at
#     the top of every file fail and the report is just noise.
{ pkgs, ... }:

let
  src = ./../../programs/pi-chat;
in
pkgs.runCommand "pi-chat-qmllint"
  {
    nativeBuildInputs = [ pkgs.qt6.qtdeclarative ];
    inherit src;
    qsModules = "${pkgs.quickshell}/lib/qt-6/qml";
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
