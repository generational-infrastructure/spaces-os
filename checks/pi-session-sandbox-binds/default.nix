# sandboxBinds contract test for the chat plugin.
#
# Mounts PiSession with a user-supplied sandboxBinds list and asserts
# the produced systemd-run argv contains exactly the BindPaths /
# BindReadOnlyPaths entries each fixture declares — covering rw/ro
# modes, %h/%t specifier expansion, explicit targets, optional
# (missing-source-tolerant) binds, and order preservation.
#
# No pi binary, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-sandbox-binds-test"
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
