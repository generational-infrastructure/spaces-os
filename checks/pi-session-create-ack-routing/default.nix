# Create-ack routing contract test.
#
# The panel correlates create acks by the client-minted requestId the
# daemon echoes verbatim on the created ack. A plain attach ack for a
# persisted session racing an in-flight create must never be taken for
# the create's ack — pre-fix (FIFO resolution, no correlation id) it
# was, stamping the attached session's daemon id onto the creating
# entry (two tabs sharing one daemon session). The fake daemon forces
# the racing interleave deterministically.
#
# Real PiChatBackend (headless quickshell) against a scripted python
# fake daemon. No pi, no LLM, no VM. ~5-10s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-create-ack-routing-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
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
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
