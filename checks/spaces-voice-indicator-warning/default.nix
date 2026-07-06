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
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-voice-indicator-warning";
  dir = ./.;
  pluginDir = ../../programs/noctalia-voice-indicator;
}
