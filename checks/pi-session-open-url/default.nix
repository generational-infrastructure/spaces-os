# OpenUrlListener round-trip test.
#
# Verifies that the QML listener:
#   * accepts a valid `{"url":"https://…"}` line and forwards the URL,
#   * rejects file:// (or any non-http) schemes,
#   * skips malformed JSON without crashing.
#
# No daemon, no pi, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-open-url";
  dir = ./.;
}
