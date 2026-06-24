# Stale daemon-session recovery contract test.
#
# sessions.json points at a daemonSessionId the daemon does not know
# (state wiped / deleted elsewhere). The attach bounces with a
# correlated "no such session"; the panel session must drop the stale
# mapping, mint a fresh daemon session, populate models, and persist
# the new mapping — instead of wedging attached-but-dead with every
# command bouncing (the production "panel shows no models" wedge).
# Also pins re-stamping the legacy executor:"" pin with the default
# executor id once the inventory loads.
#
# Real PiChatBackend (headless quickshell) against a real pi-sessiond
# with the shared mock LLM. No VM, no compositor. ~10-30s.
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  harness = ../pi-session-quick-launch;
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-session-stale-recovery-test"
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
    # The daemon requires the Landlock launcher; the passthrough stub stands in
    # (driver.py inherits this via os.environ.copy() into the daemon's env).
    export SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/pi-landlock-exec
    python3 ${./driver.py} \
      ${pkgs.lib.getExe daemon} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${harness}/mock-llm.py \
      ${stubs.systemdRun}/bin/systemd-run \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
