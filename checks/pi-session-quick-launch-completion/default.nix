# Launch-bar completion UI contract test.
#
# Drives the real `completer` controller (QuickBarCompletion.qml) through
# headless quickshell and asserts the plan's §4.2 keyboard table, the §4a
# behavioural edges, and the async "candidates not ready yet" path. The
# controller is hosted in a FloatingWindow with a real PiChatBackend whose
# model cache is seeded deterministically — the offscreen platform ships no
# layer-shell, so the real QuickBar PanelWindow can't be realised (same
# reason pi-chat-panel-width hosts Panel in a FloatingWindow).
#
# No pi worker, no LLM: completion is pure UI logic over a seeded cache, so
# the launch path only needs the backend to mint a session entry. ~5-10s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-quick-launch-completion-test"
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
