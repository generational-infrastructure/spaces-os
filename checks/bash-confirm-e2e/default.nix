# End-to-end test for the bash-confirm pi extension talking pi RPC.
#
# Spawns a mock OpenAI Chat Completions server in the build sandbox,
# then drives pi --mode rpc with bash-confirm + llama-swap-discover
# loaded. Asserts that pi emits an extension_ui_request{method=confirm}
# for every bash tool call and respects the user's allow/deny response.
#
# No VM — pi runs as a normal process. The shell-level
# systemd plumbing is exercised separately by checks.test-machine.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
in
pkgs.runCommand "bash-confirm-e2e-test"
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
