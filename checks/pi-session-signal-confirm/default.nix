# Contract test for SignalConfirm.qml.
#
# Mounts the QML component pointed at a Python fake of the
# distro-signal-bridge panel socket and exercises the subscribe /
# snapshot / added / removed / approve / deny state machine. Real
# bridge behaviour is covered by packages/signal-cli/test_bridge.py;
# this isolates the QML/IPC layer so a regression in either lands
# at the right blame surface.
#
# No pi, no LLM, no compositor. ~5-8s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-signal-confirm-test"
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
