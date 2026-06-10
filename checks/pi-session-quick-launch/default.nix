# Quick-launch background-agent contract test.
#
# Drives the real PiChatBackend through headless quickshell against a REAL
# pi-sessiond executor (bun, embedding pi via its SDK) backed by a mock LLM,
# and asserts the Mod+/ fire-and-forget path: backend.launchBackground(prompt)
# creates exactly ONE session pinned to the "host" executor WHILE THE PANEL
# IS HIDDEN (create_session over the WebSocket), the daemon runs the turn and
# streams the reply back, and a stub `notify-send` records exactly one
# "Agent finished" notification on completion.
#
# The executor topology is injected as JSON via $SPACES_PI_CHAT_EXECUTORS
# (the panel's test seam; the root-owned /etc/spaces/pi-chat.json can't be
# written in the build sandbox). The daemon's per-command bash confinement
# wrapper is a passthrough stub — no bash tool commands run here.
#
# No VM, no compositor. ~10-30s.
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  # The daemon execs $SPACES_SESSIOND_SYSTEMD_RUN around every bash tool
  # command; this check never runs one, so the sidechannel check's
  # passthrough stub just satisfies the env contract.
  stub = pkgs.runCommandLocal "systemd-run-stub" { nativeBuildInputs = [ pkgs.bash ]; } ''
    install -Dm755 ${../pi-sessiond-sidechannel/systemd-run-stub} $out/bin/systemd-run
    patchShebangs $out/bin/systemd-run
  '';
in
pkgs.runCommand "pi-session-quick-launch-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.python3
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
    python3 ${./driver.py} \
      ${pkgs.lib.getExe daemon} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./mock-llm.py} \
      ${stub}/bin/systemd-run \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
