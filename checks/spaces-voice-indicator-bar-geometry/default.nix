# Spaces Voice Indicator — bar-pulse glow geometry test.
#
# Instantiates the plugin's BarPulseGeometry.qml headless against stubbed
# qs.Commons Settings/Style singletons and asserts the recording glow's
# bloom rectangle tracks every noctalia bar configuration: all four
# positions, per-monitor visibility, and floating/framed insets.
#
# Only the geometry math is exercised here; BarPulse.qml's PanelWindow /
# layer-shell wrapper needs a real compositor and is covered by the VM
# path. ~3-5s.
{ pkgs, ... }:
pkgs.runCommand "spaces-voice-indicator-bar-geometry-test"
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
