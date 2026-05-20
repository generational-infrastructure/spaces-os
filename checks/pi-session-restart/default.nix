# RPC new_session contract test. Boots pi --mode rpc against the
# streaming mock LLM, drives one turn, sends `{ type: "new_session" }`,
# then asserts that pi reports a fresh sessionId and an empty message
# list afterwards. This is the contract the chat plugin's restart
# button depends on (PiSession.restart() → IPC new_session).
#
# No VM — pi runs as a normal sandbox process.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "pi-session-restart-test"
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
      ${../pi-rpc-streaming/mock-llm.py} \
      "$extDir" \
      "$work"
    touch $out
  ''
