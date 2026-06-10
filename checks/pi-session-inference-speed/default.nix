# PiSession inference-speed (tokens/second) component test.
#
# Injects a synthetic text_start/text_delta/text_end stream followed by
# a message_end carrying provider usage, and asserts that PiSession
# computes tps from `usage.output / wall-clock` and patches the text
# bubble with `tps` + `outputTokens`. Also checks the negative paths:
# message_end without usage, or with usage.output=0, or before any
# text bubble, must not synthesize a tps value.
#
# No pi-sessiond, no executor, no LLM, no compositor. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-session-inference-speed-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    pluginDir = ../../programs/pi-chat;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
