# Message-entry schema contract test.
#
# Exercises the pure message module (programs/pi-chat/Msg.js): every
# constructor must yield the full 8-field record ({id, from, text, ts,
# state, image, replyTo, type}), the predicates must
# discriminate the stringly type tags (incl. the empty-type
# plain-assistant case and legacy records with no `type` key at all),
# and the streaming patch helpers must be pure array-in/array-out with
# an identity result when the target id is absent.
#
# The module imports nothing from QML, so this needs no PiChatBackend,
# no pi worker and no mock LLM — just headless quickshell importing the
# real Msg.js and a driver that drives it over IPC. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-msg-schema-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    msgJs = ../../programs/pi-chat/Msg.js;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      "$msgJs" \
      ${./.} \
      "$work"
    touch $out
  ''
