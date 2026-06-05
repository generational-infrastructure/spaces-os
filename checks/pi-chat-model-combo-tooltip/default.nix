# NComboBox model-name truncation-tooltip component test.
#
# Hosts the real NComboBox in a headless quickshell, instantiates its row
# delegate at a narrow vs. wide width, and asserts the delegate elides
# (truncated) only when the label overflows while always exposing the
# full name the hover tooltip renders.
#
# No pi process, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-model-combo-tooltip-test"
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
