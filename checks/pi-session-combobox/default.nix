# NComboBox dropdown popup-geometry component test.
#
# Hosts the panel's NComboBox in a headless quickshell window, opens
# its popup over IPC, and asserts the popup gains a real (non-zero)
# height — i.e. the model selector dropdown actually expands.
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-combobox";
  dir = ./.;
}
