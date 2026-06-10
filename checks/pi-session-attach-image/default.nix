# Attach-image contract test for the chat plugin, end-to-end over WS.
#
# PiSession has no local pi-spawn path; images travel panel -> WS `prompt`
# command -> pi-sessiond -> embedded pi SDK -> LLM. This check runs the real
# PiChatBackend (headless quickshell, executor injected via
# $SPACES_PI_CHAT_EXECUTORS with a tokenPath) against the REAL pi-sessiond
# (bun) backed by a recording mock LLM, drives `sendFile(<tiny png>)` through
# quickshell's IPC, and asserts:
#
#   - a local "from: me" bubble carrying the image path appears immediately
#     (the regression that made the paperclip button silently drop
#     attachments); and
#   - the recorded /v1/chat/completions request body contains the PNG's exact
#     base64 payload — the panel-encoded image really reached the model.
#
# Runs as a normal sandbox build via `pkgs.runCommand` (loopback only).
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;

  # No user-mode systemd in the sandbox; the daemon's bash tool confinement
  # wrapper is stubbed out (never exercised here — the mock LLM emits no
  # tool calls).
  stub = pkgs.runCommandLocal "systemd-run-stub" { nativeBuildInputs = [ pkgs.bash ]; } ''
    install -Dm755 ${./systemd-run-stub} $out/bin/systemd-run
    patchShebangs $out/bin/systemd-run
  '';
in
pkgs.runCommand "pi-session-attach-image-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      # The panel-side image reader shells out to `file -b --mime-type` and
      # `base64 -w0` — keep both on PATH.
      pkgs.coreutils
      pkgs.bash
      pkgs.file
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
    # qtbase's qpa offscreen plugin lives under $QT_PLUGIN_PATH; the wrapped
    # quickshell already exports it but pkgs.runCommand strips that wrapper.
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    # PiExecutor imports QtWebSockets, which lives outside quickshell's
    # bundled QML path — add it on both the Qt and the nixpkgs import vars.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${pkgs.lib.getExe daemon} \
      ${stub}/bin/systemd-run \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
