# Correspondence contract test for the panel↔daemon session registry.
#
# Exercises the pure fold (programs/pi-chat/SessionRegistry.js): replays
# the table-driven scenario corpus under ./fixtures — import cutoffs,
# claim-by-requestId, pending-create deferral, upstream removals gated on
# per-connection observation — through the registry interface and asserts
# the resulting index entries and per-op trace. PiChatBackend, PiExecutor
# and PiSession are only clients of this module; every session-list race
# the panel ever had lived in the logic this corpus pins.
#
# The module is dependency-free, so this needs no PiSession, no daemon
# and no mock LLM — just headless quickshell importing the real
# SessionRegistry.js and a driver that drives it over IPC. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-session-registry-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    registryJs = ../../programs/pi-chat/SessionRegistry.js;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      "$registryJs" \
      ${./.} \
      "$work"
    touch $out
  ''
