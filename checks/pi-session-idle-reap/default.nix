# Idle-reap exemption contract test.
#
# Asserts PiChatBackend._reapIdle() leaves an actively-generating
# background launch alone while still reaping a running-but-idle
# session. Guards the regression where the idle timer killed every
# running pi worker — including a long fire-and-forget task — 10 min
# after the chat panel closed.
#
# Reuses the quick-launch check's mock LLM (with its hold-on-"HOLD"
# behaviour), test shell.qml and systemd-run / notify-send stubs; adds a
# systemctl stub that records which units the reaper decided to stop.
#
# No VM, no compositor. ~10-20s.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "pi-session-idle-reap-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    extDir = ../../modules/nixos/pi-chat/extensions;
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
      ${pkgs.lib.getExe piPkg} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${../pi-session-quick-launch/mock-llm.py} \
      "$extDir" \
      ${../pi-session-quick-launch} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
