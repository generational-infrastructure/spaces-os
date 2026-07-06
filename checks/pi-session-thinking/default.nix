# PiSession thinking-event handler component test.
#
# Injects mock pi RPC thinking events into PiSession via quickshell
# IPC and asserts that thinking bubbles appear, stream, finalise, and
# that empty thinking blocks are cleaned up.
#
# No pi-sessiond, no executor, no LLM, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-thinking";
  dir = ./.;
}
