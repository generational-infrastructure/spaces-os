# PiSession thinking-event handler component test.
#
# Injects mock pi RPC thinking events into PiSession via quickshell
# IPC and asserts that thinking bubbles appear, stream, finalise, and
# that empty thinking blocks are cleaned up.
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-thinking-test"
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
