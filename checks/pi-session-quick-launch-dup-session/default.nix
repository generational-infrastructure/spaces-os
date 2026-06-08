# Quick-launch duplicate-session regression.
#
# Drives the real PiChatBackend (headless quickshell) against a fake
# pi-sessiond that broadcasts the §12 `sessions` list immediately after each
# create_session ack — the exact sequence the real daemon emits. With a single
# REMOTE executor configured (injected as JSON via $SPACES_PI_CHAT_EXECUTORS,
# since the root-owned /etc/spaces/pi-chat.json can't be written in the sandbox)
# and a seeded sessions.json (the returning desktop that arms lastImportTime)
# this reproduces the duplicate-session bug: launchBackground's spawn()-then-send()
# issued a SECOND create_session while the first was in flight; the daemon
# minted two sessions, the panel entry could keep only one, and the broadcast
# re-imported the orphaned id as a dead duplicate.
#
# Asserts exactly ONE index entry after a remote double-spawn, and that the
# quick-bar session follows defaultExecutor (the lone remote here) while
# staying single through the launchBackground path too. No real pi/LLM, no
# compositor, no VM. ~10-20s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-quick-launch-dup-session-test"
  {
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
    # PiExecutor imports QtWebSockets, which lives outside quickshell's bundled
    # QML path — add it on both the Qt and the nixpkgs import-path vars.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
