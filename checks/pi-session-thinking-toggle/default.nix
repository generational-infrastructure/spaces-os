# Chat panel thinking-visibility toggle component test.
#
# Drives PiSession through real thinking RPC events, then asserts that
# the panel's MsgFilter helper hides/restores thinking bubbles in the
# visible model without mutating the underlying session state.
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-thinking-toggle-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    pluginDir = ../../programs/pi-chat-plugin;
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
