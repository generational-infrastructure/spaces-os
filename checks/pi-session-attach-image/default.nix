# Attach-image contract test for the chat plugin.
#
# Mounts PiSession.qml inside a tiny test shell (no noctalia, no NixOS
# module, no compositor) and drives `sendFile(<image_path>)` through
# quickshell's IPC. Asserts that a local "from: me" message bubble
# carrying the image path appears immediately — the regression that
# made the paperclip button silently drop attachments.
#
# Runs as a normal sandbox build via `pkgs.runCommand`.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "pi-session-attach-image-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.file
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
    # qtbase's qpa offscreen plugin lives under $QT_PLUGIN_PATH; the
    # wrapped quickshell already exports it but pkgs.runCommand strips
    # that wrapper, so we set the env explicitly. Same for the QML
    # import path so PiSession.qml resolves Quickshell + Quickshell.Io.
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe piPkg} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${../pi-rpc-streaming/mock-llm.py} \
      "$extDir" \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
