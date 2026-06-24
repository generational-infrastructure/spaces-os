# Strict qmllint pass over every QML file under the agent-sessions
# plugin (`programs/noctalia-spaces-sessions/`).
#
# `--max-warnings 0` turns any warning into a build failure.
#
# Like the voice-indicator check, this plugin imports noctalia-shell's
# runtime modules (`import qs.Commons` / `qs.Widgets`), so `mkQsImports`
# mirrors noctalia-shell's QML tree as `qs/` with synthesised qmldir
# files for resolution; only the plugin files globbed below are linted.
# The quickshell qmltypes shim is shared via `lib/qmllint.nix`.
{ pkgs, ... }:

let
  src = ./../../programs/noctalia-spaces-sessions;
  qmllint = import ../../lib/qmllint.nix pkgs;
  noctaliaImports = qmllint.mkQsImports {
    name = "noctalia";
    tree = "${pkgs.noctalia-shell}/share/noctalia-shell";
  };
in
pkgs.runCommand "spaces-sessions-qmllint"
  {
    nativeBuildInputs = [ pkgs.qt6.qtdeclarative ];
    inherit src;
    qsImports = noctaliaImports;
    qsModules = qmllint.quickshellShim;
    qtModules = "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml";
  }
  ''
    set -euo pipefail

    # Glob the whole tree so newly added components are covered without
    # editing this check.
    mapfile -t files < <(find "$src" -name '*.qml' | sort)

    qmllint \
      -I "$qsImports" \
      -I "$qsModules" \
      -I "$qtModules" \
      --max-warnings 0 \
      "''${files[@]}"

    touch "$out"
  ''
