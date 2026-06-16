# Chat history scroll-behaviour regression test (issue #28).
#
# Embeds the real chat Panel with a stub backend and drives its history
# ListView over IPC: scroll up, then stream tokens into the newest
# bubble. The view must hold the reader's scrollback instead of snapping
# to the bottom on every token, while a bottom-pinned reader keeps
# following the newest message.
#
# No pi process, no LLM, no compositor. ~5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-scroll-stick-test"
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
