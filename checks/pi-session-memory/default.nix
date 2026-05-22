# Integration test for the memory pi extension talking pi RPC.
#
# Spawns a mock OpenAI Chat Completions server in the build sandbox
# plus a stub sediment binary, then drives pi --mode rpc with the
# memory + llama-swap-discover extensions loaded. Asserts that pi
# fires the agent_end hook (→ extractor LLM side-call → sediment
# store) and the before_agent_start hook (→ sediment recall →
# <recalled_memories> injected into the next system prompt).
#
# No VM, no real sediment, no embedding-model download — the shell-
# level systemd plumbing for the real extension is exercised in the
# `services.pi-chat` module config; the integration with pi's
# extension surface is what this check covers.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "pi-session-memory-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    extDir = ../../modules/nixos/pi-chat/extensions;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    python3 ${./driver.py} \
      ${pkgs.lib.getExe piPkg} \
      ${./mock-llm.py} \
      "$extDir/memory/index.ts" \
      ${./sediment-stub.py} \
      "$work"
    touch $out
  ''
