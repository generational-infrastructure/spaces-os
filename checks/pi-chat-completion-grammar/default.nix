# Launch-bar grammar contract test.
#
# Exercises the pure parser (programs/pi-chat/BarParse.js) over the
# grammar/behaviour matrix from the launch-bar completion plan: leading
# slash-directives, the load-bearing `:`-in-value split
# (/model:gemma4:e4b → value "gemma4:e4b"), last-wins duplicates, bare
# commands, non-leading slashes as prose, and cursor-relative partials.
#
# The parser imports nothing from QML, so this needs no PiChatBackend,
# no pi worker and no mock LLM — just headless quickshell importing the
# real BarParse.js and a driver that drives parse() over IPC. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "pi-chat-completion-grammar-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    barParse = ../../programs/pi-chat/BarParse.js;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      "$barParse" \
      ${./.} \
      "$work"
    touch $out
  ''
