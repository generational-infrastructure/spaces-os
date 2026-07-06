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
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-voice-indicator-bar-geometry";
  dir = ./.;
  pluginDir = ../../programs/noctalia-voice-indicator;
}
