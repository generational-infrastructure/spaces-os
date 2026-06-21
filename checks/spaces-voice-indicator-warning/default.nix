# Spaces Voice Indicator — warning visual-mapping component test.
#
# Loads the plugin's real BarWidget.qml in a headless quickshell against stub
# noctalia singletons (Color/Style/TooltipService/NIcon) staged as the `qs`
# shell root, drives the service state over IPC, and asserts the derived
# glyph / colour / tooltip / visibility. This pins the shared visual contract
# — the no-speech warning recolours the idle mic to the mTertiary caution
# tone (distinct from recording red and transcribing amber), keeps the
# matching tooltip, and stays visible even under hideWhenIdle — without
# needing a full compositor / agent-vm screenshot. ~3-10s.
{ pkgs, ... }:
pkgs.runCommand "spaces-voice-indicator-warning-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    pluginDir = ../../programs/noctalia-voice-indicator;
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
