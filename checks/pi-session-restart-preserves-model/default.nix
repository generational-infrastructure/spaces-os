# Contract test: PiSession.restart() preserves the selected model across
# the WS delete+create cycle. restart() on a daemon-backed session sends
# detach + delete_session for the old daemon session id, clears the panel
# entry's daemonSessionId, then issues a fresh create_session whose
# envelope carries model="<provider>/<id>" equal to the session's
# modelPref — sessions are cheap daemon-side, so restart is delete +
# create rather than an in-place rebind, and no set_model replay is
# needed after the fact.
#
# Drives the real PiChatBackend (headless quickshell) against a mock
# pi-sessiond (injected as JSON via $SPACES_PI_CHAT_EXECUTORS) that logs
# every frame in order. Asserts detach(D1) → delete_session(D1) →
# create_session#2{model=modelPref} on the wire, and that the panel's
# index entry rebinds to the SECOND daemon id. No real pi/LLM, no
# compositor, no VM. ~10-20s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-restart-preserves-model-test"
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
