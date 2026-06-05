# ModelFrecency scoring/sort/persistence component test.
#
# Hosts the ModelFrecency singleton in a headless quickshell, drives its
# record/sortModels surface over IPC with injected timestamps, and
# asserts frecency ordering (recency dominates, frequency lifts among
# equal recency, never-used keep backend order) plus persistence across
# a FileView reload.
#
# No pi process, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-model-frecency-test"
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
