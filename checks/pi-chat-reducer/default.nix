# Event-fold contract test for the chat panel's pi-event reducer.
#
# Exercises the pure fold (programs/pi-chat/Reducer.js): replays the
# fixture corpus under ./fixtures — canonical pi event streams
# (agent_start, text/thinking deltas, message_end usage, tool notices,
# extension_ui/approval requests, remote user mirroring) — through
# Reducer.apply and asserts the resulting message arrays, flags, and
# effects. checks/pi-web-reducer replays the SAME corpus through
# packages/pi-web/reducer.ts and asserts the same renderer-agnostic
# projection, so the two folds cannot drift apart silently.
#
# The module imports only Msg.js, so this needs no PiSession, no pi
# worker and no mock LLM — just headless quickshell importing the real
# Reducer.js and a driver that drives it over IPC. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-reducer-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    reducerJs = ../../programs/pi-chat/Reducer.js;
    msgJs = ../../programs/pi-chat/Msg.js;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      "$reducerJs" \
      "$msgJs" \
      ${./.} \
      "$work"
    touch $out
  ''
