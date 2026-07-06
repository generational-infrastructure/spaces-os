# Contract test for NdjsonSocket.qml — the one shared unix-socket
# adapter behind SignalConfirm, PiChatBackend's skill-config sidecar,
# IntegrationsBridge and OpenUrlListener.
#
# Drives both client modes against in-driver python socket fixtures:
#   subscribe — hello line on connect, line-buffered JSON delivery,
#               bad-line rejection, send(), reconnect with backoff
#               after the peer vanishes, backoff reset on success;
#   request   — one-shot connect→send→single reply→close, malformed
#               reply, reply timeout, close-without-reply.
#
# No pi, no LLM, no compositor. ~5-10s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-ndjson-socket-test"
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
