# Chat-panel palette-tracking component test.
#
# Drives the panel's Color singleton in a headless quickshell with a
# private noctalia config dir, then asserts the palette both loads from
# colors.json on startup and live-updates when the file is rewritten
# (a colour edit or a light/dark switch).
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-noctalia-theme";
  dir = ./.;
}
