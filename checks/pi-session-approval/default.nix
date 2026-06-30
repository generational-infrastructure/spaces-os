# Headless check: the chat panel renders an integration tool-call approval
# (the new `approval_request` event) and replies the user's {once|session|deny}
# decision over the §12 WebSocket transport.
#
# Drives the real PiExecutor + PiSession against a fake gateway and asserts the
# bubble carries the gateway's tool/args and that each decision crosses the
# wire as an approval_response. The cheap per-feature counterpart to the full
# VM test — no compositor, pi, LLM, or VM. ~5s.
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-session-approval-test"
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
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
