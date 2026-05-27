# Streaming check: pi --mode rpc ↔ mock OpenAI Chat Completions.
#
# Asserts that text_delta events arrive at the RPC client in real time
# (not buffered into a single message_end). Used as a smoke test for
# the streaming-decoder seam between pi and any RPC consumer — the
# pi-chat panel, our own driver here, anything that reads pi's
# stdout JSONL.
#
# No VM. Pi runs as a normal sandbox process.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "pi-rpc-streaming-test"
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
      "$extDir" \
      "$work"
    touch $out
  ''
