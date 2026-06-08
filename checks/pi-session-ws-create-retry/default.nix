# Headless check: a create_session lost to a connection flap is retried.
#
# Runs the real PiExecutor + PiSession (WS mode) against a fake pi-sessiond
# that drops the first create_session mid-flight (no ack) and accepts it only
# on reconnect — the boot-time flap the real daemon shows while coming up. A
# single send()'s prompt must survive the flap: the panel reconnects, RETRIES
# the create, attaches, and flushes the buffered prompt so the reply streams.
#
# Guards the failure mode a spawn-idempotency guard invites: with repeat
# spawns coalesced onto one in-flight create, the retry must live in the
# create path itself (_wsCreate) or the prompt sits buffered forever. The
# heavy pi-chat-remote VM test otherwise catches this only under a real boot
# flap. No compositor, pi, LLM, or VM. ~5s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-ws-create-retry-test"
  {
    nativeBuildInputs = [
      py
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
      pkgs.qt6.qtwebsockets
    ];
    pluginDir = ../../programs/pi-chat;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
