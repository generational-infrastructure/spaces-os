# Panel.qml surface-width regression test.
#
# Embeds the real chat Panel inside a 480 px-wide FloatingWindow the
# way shell.qml embeds it inside a 480 px PanelWindow, and asserts
# the Panel does NOT drag the surface wider than the shell asked for.
#
# Guards the bug where Panel.qml's leftover SmartPanel
# `implicitWidth: contentPreferredWidth (1000)` propagated up through
# QQuickWindow's contentItem and made the wayland surface ~1000 px,
# clipping the header buttons and every chat bubble off the right
# edge of the screen.
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-panel-width-test"
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
