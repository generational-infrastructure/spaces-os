# PiSession inference-speed (tokens/second) attribution component test.
#
# Injects mock pi RPC events into PiSession via quickshell IPC and asserts
# message_end usage patches the text bubble with tps/outputTokens, zero
# usage and end-before-start leave bubbles untouched, and agent_end resets
# the tps clock.
#
# No pi-sessiond, no executor, no LLM, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-inference-speed";
  dir = ./.;
}
