# ModelFrecency scoring/sort/persistence component test.
#
# Hosts the ModelFrecency singleton in a headless quickshell, drives its
# record/sortModels surface over IPC with injected timestamps, and
# asserts frecency ordering (recency dominates, frequency lifts among
# equal recency, never-used keep backend order) plus persistence across
# a FileView reload.
#
# No pi process, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-model-frecency";
  dir = ./.;
}
