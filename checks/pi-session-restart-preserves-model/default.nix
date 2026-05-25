# Contract test: PiSession.restart() re-asserts set_model so a fresh pi
# session resumes on the user's previously selected model instead of
# silently falling back to settings.json's default. The dropdown is a
# QML-side intent (modelPref); pi's new_session command does not carry
# it across, so PiSession is responsible for replaying it.
#
# Headless quickshell only — fake pi, stub systemd-run, no compositor,
# no LLM. ~5s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-restart-preserves-model-test"
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
