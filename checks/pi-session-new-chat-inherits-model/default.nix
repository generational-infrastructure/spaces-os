# New-chat model inheritance contract test.
#
# A brand-new chat session must default to the model the user most
# recently selected (max lastUsed in the frecency store), not to pi's
# settings.json default. The inherited model must also be applied on
# the fresh local session's first spawn, race-free. pi dispatches
# stdin lines as fire-and-forget async tasks, so the first prompt may
# only go out after pi acked the set_model. Unlike the explicit
# /model: directive, which aborts on failure, the implicit inheritance
# degrades gracefully. A rejected set_model logs a warning and the
# prompt still runs on pi's default.
#
# Headless quickshell hosting the real PiChatBackend with a fake pi
# and a stub systemd-run. No compositor, no LLM. ~5-10s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-new-chat-inherits-model-test"
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
    # PiChatBackend instantiates PiExecutor, which imports QtWebSockets.
    # That module lives outside quickshell's bundled QML path, so add it
    # explicitly.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
