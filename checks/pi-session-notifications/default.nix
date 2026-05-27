# End-to-end test for the `notifications` skill.
#
# Boots pi --mode rpc with the bash-confirm extension loaded and the
# `notifications` CLI on PATH, points it at a tmpdir holding a seeded
# notifications history file, then asserts that:
#
#   1. Pi never asks for a confirm prompt — the bash-confirm allowlist
#      whitelists `notifications` so the command runs straight through.
#   2. The seeded notification's summary surfaces in the assistant reply
#      (the mock LLM echoes the tool result back to prove pi actually
#      ran the CLI and not a stub).
#
# No VM. The full notification-history writer ⇄ pi wiring still rides
# (checks/test-machine.nix) — this check covers the skill + sandbox
# bind/env story in isolation, in ~seconds.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
  notificationsCli = pkgs.callPackage ../../packages/notifications-cli { };
in
pkgs.runCommand "pi-session-notifications-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    extDir = ../../modules/nixos/pi-chat/extensions;
    notificationsBin = pkgs.lib.getExe notificationsCli;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    python3 ${./driver.py} \
      ${pkgs.lib.getExe piPkg} \
      ${./mock-llm.py} \
      "$extDir" \
      "$notificationsBin" \
      "$work"
    touch $out
  ''
