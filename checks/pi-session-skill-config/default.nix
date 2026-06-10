# Skill-config prompt round-trip test.
#
# Boots the skill-config-daemon and an offscreen quickshell with a
# test shell that subscribes to the daemon socket. The driver runs
# the REAL `skill-config request-input` CLI binary (same one pi uses
# from inside its pi-sessiond sandbox) against a staged test-skill, asserts the
# prompt bubble appears, submits a value, and verifies the CLI exits 0
# with the value persisted to config.toml.
#
# No pi process, no pi-sessiond, no LLM, no compositor. ~5s.
{ pkgs, inputs, ... }:
let
  skillConfigDaemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config-daemon;
  skillConfig = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config;
in
pkgs.runCommand "pi-session-skill-config-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
      skillConfigDaemon
      skillConfig
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
      ${pkgs.lib.getExe skillConfigDaemon} \
      ${pkgs.lib.getExe skillConfig} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
