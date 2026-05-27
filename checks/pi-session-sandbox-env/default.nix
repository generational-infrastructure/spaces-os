# Sandbox-env contract test for the pi-chat shell.
#
# Mounts PiSession and asserts the systemd-run argv it builds forwards
# the chat shell's PATH into the transient unit. Without `--setenv=PATH=`,
# transient services created by `systemd-run --user` only inherit the
# user manager's Manager.Environment — on NixOS that is just the
# user@.service PATH (coreutils + systemd's bin), and every skill CLI
# shelled out by bare name from SKILL.md (signal, notifications,
# skill-config, …) ENOENTs on compositors that don't run
# `systemctl --user import-environment` at session start (sway,
# hyprland, GNOME, …).
#
# No pi binary, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-sandbox-env-test"
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
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
