# Correspondence contract test for the panel↔daemon session registry.
#
# Exercises the pure fold (programs/pi-chat/SessionRegistry.js): replays
# the table-driven scenario corpus under ./fixtures — import cutoffs,
# claim-by-requestId, pending-create deferral, upstream removals gated on
# per-connection observation — through the registry interface and asserts
# the resulting index entries and per-op trace. PiChatBackend, PiExecutor
# and PiSession are only clients of this module; every session-list race
# the panel ever had lived in the logic this corpus pins.
#
# The module is dependency-free, so this needs no PiSession, no daemon
# and no mock LLM — just headless quickshell importing the real
# SessionRegistry.js and a driver that drives it over IPC. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-session-registry";
  dir = ./.;
}
