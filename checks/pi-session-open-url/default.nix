# OpenUrlListener round-trip test.
#
# Verifies that the QML listener:
#   * accepts a valid `{"url":"https://…"}` line and forwards the URL,
#   * rejects file:// (or any non-http) schemes,
#   * skips malformed JSON without crashing.
#
# No daemon, no pi, no compositor. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-open-url-test"
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
