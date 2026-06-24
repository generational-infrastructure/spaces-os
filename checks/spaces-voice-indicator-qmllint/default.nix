# Strict qmllint pass over every QML file under the voice-indicator
# plugin (`programs/noctalia-voice-indicator/`).
#
# `--max-warnings 0` turns any warning into a build failure.
#
# Unlike pi-chat, this plugin imports noctalia-shell's runtime modules
# (`import qs.Commons` / `qs.Services.UI` / `qs.Widgets` resolve to
# Color/Settings/Style/NIcon/TooltipService, which are noctalia's, not
# ours). `mkQsImports` mirrors noctalia-shell's QML tree as `qs/` with
# synthesised qmldir files so those imports resolve; noctalia's own files
# are only on `-I`, so qmllint reports warnings solely for the plugin
# files globbed below. The quickshell qmltypes shim (PanelWindow,
# FileView.adapter, Process/Socket enums, Margins) is shared with the
# other qmllint checks via `lib/qmllint.nix`.
{ pkgs, ... }:

let
  src = ./../../programs/noctalia-voice-indicator;
  qmllint = import ../../lib/qmllint.nix pkgs;
  noctaliaImports = qmllint.mkQsImports {
    name = "noctalia";
    tree = "${pkgs.noctalia-shell}/share/noctalia-shell";
  };
in
pkgs.runCommand "spaces-voice-indicator-qmllint"
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
