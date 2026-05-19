# Three-tier streaming check: real opencrow ↔ real pi ↔ Python mock LLM.
#
# Asserts kind:"delta" events reach the chat socket in real time when
# pi streams a four-chunk reply from the mock. No GPU, no OpenRouter,
# no VM; runs in a few seconds in the sandbox.
#
# This is the cheapest regression test for opencrow's decoder of the
# real pi-stdout protocol. A pi-only check (mock LLM, no opencrow)
# would miss bugs in opencrow's rpcEvent decode — like the
# `ConfirmMessage string json:"message"` collision in pi_rpc.go that
# dropped every message_update silently. An opencrow-only check
# (stub pi) would miss the same bug because the stub never emits the
# object-typed `message` field pi-mono attaches to every update.
# Pairing both into one test catches the integration regression
# without paying for a VM or a remote provider.
{ pkgs, inputs, ... }:
let
  inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) pi;
  inherit (inputs.opencrow.packages.${pkgs.stdenv.hostPlatform.system}) opencrow;
  discoverExt = ../../modules/nixos/opencrow/llama-swap-discover.ts;
  mockLlm = ./mock-llm.py;
in
pkgs.runCommand "streaming-pi-opencrow-e2e-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    python3 ${./driver.py} \
      ${opencrow}/bin/opencrow \
      ${pi}/bin/pi \
      ${mockLlm} \
      ${discoverExt} \
      "$work"
    touch $out
  ''
