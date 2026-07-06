# Spaces Agent Sessions — activity.json producer/consumer contract test.
#
# The sessions bar (programs/noctalia-spaces-sessions/Main.qml) consumes
# the activity feed that pi-chat's PiChatBackend._writeActivity publishes
# at ~/.local/state/spaces/pi/activity.json:
#   { version, activeSessionId, sessions: [{ id, name, state }] }
#   state ∈ "working" | "waiting"
# That schema is an implicit contract living in comments; drift breaks
# the bar silently and only the full VM test would catch it. This check
# hosts the consumer's Main.qml FileView service in a headless
# quickshell, writes literal fixture files replicating the producer's
# output, and asserts the resulting model state over the quickshell IPC
# CLI: empty feed, working+waiting mix, active-session highlight,
# unknown-extra-field tolerance, version-bump tolerance (the consumer
# ignores `version`), keep-previous on a torn/partial read, the
# non-array `sessions` guard, and blank-on-removal.
#
# Main.qml imports only QtQuick/Quickshell/Quickshell.Io, so it runs
# standalone with no noctalia modules. No pi-chat, no compositor. ~3-10s.
{ pkgs, ... }:
pkgs.runCommand "spaces-activity-contract-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    pluginDir = ../../programs/noctalia-spaces-sessions;
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
