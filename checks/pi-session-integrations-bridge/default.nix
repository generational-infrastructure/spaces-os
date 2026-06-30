# Contract test for IntegrationsBridge.qml — the panel's client for the
# per-user integrations broker (spaces-integrationd).
#
# Mounts the component pointed at a Python fake of the broker socket and
# exercises the provisioning state machine the settings form relies on: list,
# the enable-without-secret guard, set-secret, enable, disable. Real broker
# behaviour is covered by packages/spaces-integrationd; this isolates the
# QML/IPC layer so a regression in either lands at the right blame surface.
#
# No pi, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-integrations-bridge-test"
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
