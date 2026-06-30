# Unit test for the spaces-integrations pi extension
# (modules/nixos/pi-chat/extensions/spaces-integrations.ts).
#
# Builds a minimal Nix derivation that runs Node's built-in test runner against
# the extension's pure logic — no pi, no daemon, no VM. Catches regressions in
# how it reads the per-session spec, registers a forwarding tool per entry, and
# performs the ctx.ui.input gateway round-trip (success, no-UI, cancelled, bad
# reply). The supervisor's half is checks/pi-sessiond-integration-gateway.
{ pkgs, ... }:
pkgs.runCommand "spaces-integrations-extension-test"
  {
    src = ../modules/nixos/pi-chat/extensions;
    nativeBuildInputs = [ pkgs.nodejs_22 ];
  }
  ''
    cp -r $src/. .
    chmod -R +w .
    node --test spaces-integrations.test.mjs
    touch $out
  ''
