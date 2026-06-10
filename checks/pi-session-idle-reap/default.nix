# WS-era idle-reap contract test.
#
# PiSession no longer spawns local pi workers — sessions live in a
# pi-sessiond executor over WebSocket, and the reaper moved with them:
# PiChatBackend._reapIdle() calls PiSession.stop() on idle *streaming*
# sessions, which emits a `detach` frame for the session's daemon id
# (plus a panel-local unsubscribe). Busy sessions and pending background
# launches are skipped — no frame at all. No systemctl anywhere.
#
# Drives the real PiChatBackend (headless quickshell) against a mock
# pi-sessiond that logs every inbound frame. Two background launches:
# one held mid-turn (the mock never sends agent_end, so the panel keeps
# busy=true), one completed (agent_end → idle but still attached). After
# backend._reapIdle() (invoked via the IPC seam, not the real timer) the
# frame log must show a detach for the idle session's daemon id and NONE
# for the busy one; panel flags agree (idle streaming=false, busy
# streaming=true). The executor is injected via $SPACES_PI_CHAT_EXECUTORS
# (the panel's test seam). No real pi/LLM/daemon, no compositor, no VM.
# ~10-20s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-idle-reap-test"
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
    # PiExecutor imports QtWebSockets, which lives outside quickshell's bundled
    # QML path — add it on both the Qt and the nixpkgs import-path vars.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
