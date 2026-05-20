# Skill-config prompt round-trip test.
#
# Boots the skill-config-daemon and an offscreen quickshell with a
# test shell that subscribes to the daemon socket. The driver acts
# as a CLI (request-input), asserts the prompt bubble appears in the
# session's messages, submits a value, and verifies both the CLI and
# the bubble see the result.
#
# No pi process, no LLM, no compositor. ~5s.
{ pkgs, inputs, ... }:
pkgs.runCommand "skill-config-e2e-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
      inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config-daemon
    ];
    pluginDir = ../../programs/pi-chat-plugin;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config-daemon} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
