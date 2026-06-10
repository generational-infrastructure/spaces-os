# New-chat model inheritance contract test.
#
# A brand-new chat session must default to the model the user most
# recently selected (max lastUsed in the frecency store), not to pi's
# default. PiSession is WS-only, so the inherited model must ride the
# create_session envelope itself (model="provider/id") — the daemon
# session comes up on it, race-free by construction. Entries minted
# via _freshSessionEntry (the remote-import shape) must keep model ""
# so imported daemon sessions never inherit a local pick.
#
# Headless quickshell hosting the real PiChatBackend against a mock
# pi-sessiond (injected via $SPACES_PI_CHAT_EXECUTORS) that logs every
# frame in order. No compositor, no LLM. ~10-20s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-new-chat-inherits-model-test"
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
