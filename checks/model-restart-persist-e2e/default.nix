# Regression check for the chat panel's reset button (`!restart`)
# dropping the user's selected model.
#
# Drives the real opencrow socket protocol against a two-model mock
# LLM: switches to alt-model, sends !restart, then asserts the next
# list-models still reports alt-model active. A worker that fails to
# persist set-model into PiConfig would respawn pi with the configured
# default and flip active back to mock-model — which this driver
# treats as a failure with a clear message.
#
# Mirrors checks/streaming-pi-opencrow-e2e/ wiring (real opencrow,
# real pi, Python mock) so it stays cheap to run and self-contained
# in the sandbox.
{ pkgs, inputs, ... }:
let
  inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) pi;
  inherit (inputs.opencrow.packages.${pkgs.stdenv.hostPlatform.system}) opencrow;
  discoverExt = ../../modules/nixos/opencrow/llama-swap-discover.ts;
  mockLlm = ./mock-llm.py;
in
pkgs.runCommand "model-restart-persist-e2e-test"
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
