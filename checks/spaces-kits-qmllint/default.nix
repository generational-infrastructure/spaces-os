# Strict qmllint pass over every QML file under `programs/spaces-kits/`
# (the native QML port of the spaces-kits UI kits).
#
# `--max-warnings 0` turns any warning into a build failure. Mirrors
# checks/pi-chat-qmllint: a `qs/` symlink so `import qs.Commons` /
# `import qs.Components` resolve, plus the same patched quickshell qmltypes
# (three upstream registration gaps that trip qmllint with no runtime effect).
{ pkgs, ... }:

let
  src = ./../../programs/spaces-kits;

  patchedQuickshellQml =
    pkgs.runCommand "quickshell-qmllint-shim-spaces-kits"
      {
        qs = pkgs.quickshell;
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        cp -r "$qs/lib/qt-6/qml" "$out"
        chmod -R u+w "$out"

        python3 ${../pi-chat-qmllint/patch-qmltypes.py} \
          "$out/Quickshell/_Window/quickshell-window.qmltypes" \
          "$out/Quickshell/Io/quickshell-io.qmltypes"
      '';
in
pkgs.runCommand "spaces-kits-qmllint"
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

    files=( "$src"/*.qml "$src"/Commons/*.qml "$src"/Components/*.qml )

    qmllint \
      -I "$workdir" \
      -I "$qsModules" \
      -I "$qtModules" \
      --max-warnings 0 \
      "''${files[@]}"

    touch "$out"
  ''
