# Quick-launch background-agent contract test.
#
# Drives the real PiChatBackend through headless quickshell and asserts
# the Mod+/ fire-and-forget path: backend.launchBackground(prompt)
# creates a session and spawns its `pi --mode rpc` worker WHILE THE
# PANEL IS HIDDEN, streams a reply from the mock LLM, and fires exactly
# one desktop notification on completion. A stub `systemd-run` strips
# the sandbox flags and execs the real pi directly (no user systemd
# manager in the build sandbox); a stub `notify-send` records the
# completion notification.
#
# No VM, no compositor. ~10-20s.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "pi-session-quick-launch-test"
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
      ${./mock-llm.py} \
      "$extDir" \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
