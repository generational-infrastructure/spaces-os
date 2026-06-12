# Headless check: the panel's loopback-executor wiring (pi-chat.json
# `localExecutor` -> PiChatBackend.executors entry -> WS hello with the
# per-login runtime token).
#
# Asserts the backend, pointed (via $SPACES_PI_CHAT_CONFIG) at a fixture
# config carrying `localExecutor`, materializes a "host" executor entry
# whose tokenPath is $XDG_RUNTIME_DIR/pi-sessiond-local/token, then
# authenticates against a fake pi-sessiond with the token-file content
# (hello -> welcome) — and, without `localExecutor`, keeps the executors
# list empty (the transient no-executor state; spawns defer until an
# executor is configured). No compositor, pi, LLM, or VM. ~10s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-local-executor-test"
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
    # hello/welcome (+ token check) is all this check needs from a daemon;
    # reuse the WS transport check's fake instead of forking it.
    fakeDaemon = ../pi-session-ws/fake-daemon.py;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    # quickshell finds its own modules via its wrapper's
    # NIXPKGS_QT6_QML_IMPORT_PATH; add QtWebSockets on both the Qt env var
    # and the nixpkgs one so `import QtWebSockets` resolves headless.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work" \
      "$fakeDaemon"
    touch $out
  ''
