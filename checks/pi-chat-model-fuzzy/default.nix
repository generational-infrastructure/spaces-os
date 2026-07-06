# NComboBox fuzzy model-search component test.
#
# Hosts the panel's searchable NComboBox in a headless quickshell window
# next to a known model list and the Fuzzy helper, then drives the live
# search query over IPC and asserts the dropdown filters (matching the
# displayed name, source tag included), excludes non-matches, restores
# the full list when cleared, and selects the top match on accept.
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-model-fuzzy";
  dir = ./.;
}
