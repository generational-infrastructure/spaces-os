# Host-directive launch contract test.
#
# Proves backend.launchBackground(prompt, {executor}) pins the launched
# session to the named executor and REFUSES an unknown id (rather than
# silently launching on the default). No pi worker, no LLM: the executor
# field is stamped synchronously by newSession, and a remote-pinned
# (url-less, disconnected) executor routes over WS instead of spawning a
# local pi — so the contract is pure data + control-flow. ~5-10s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-quick-launch-host-directive-test"
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
    # PiChatBackend instantiates PiExecutor, which imports QtWebSockets — it
    # lives outside quickshell's bundled QML path, so add it explicitly.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
