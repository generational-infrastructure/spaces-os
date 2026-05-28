# Chat-panel palette-tracking component test.
#
# Drives the panel's Color singleton in a headless quickshell with a
# private noctalia config dir, then asserts the palette both loads from
# colors.json on startup and live-updates when the file is rewritten
# (a colour edit or a light/dark switch).
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-noctalia-theme-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    pluginDir = ../../programs/pi-chat;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
