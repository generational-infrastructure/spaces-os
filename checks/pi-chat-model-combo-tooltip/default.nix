# NComboBox model-name truncation-tooltip component test.
#
# Hosts the real NComboBox in a headless quickshell, instantiates its row
# delegate at a narrow vs. wide width, and asserts the delegate elides
# (truncated) only when the label overflows while always exposing the
# full name the hover tooltip renders.
#
# No pi process, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-model-combo-tooltip";
  dir = ./.;
}
