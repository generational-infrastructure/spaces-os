# Headless check: the chat panel's WebSocket transport (PiExecutor +
# PiSession in WS mode) against a fake pi-sessiond.
#
# Asserts the panel connects + authenticates, creates a session, sends a
# prompt over the §12 envelope, and renders the streamed reply — the cheap
# per-feature counterpart to the full two-VM test. No compositor, pi, LLM, or
# VM. ~5s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-ws-test"
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
    # quickshell finds its own modules via its wrapper's
    # NIXPKGS_QT6_QML_IMPORT_PATH; add QtWebSockets on both the Qt env var
    # and the nixpkgs one so `import QtWebSockets` resolves headless.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
