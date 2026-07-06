# Unit test for the bash-confirm pi extension
# (packages/pi-chat-extensions/bash-confirm.ts).
#
# Builds a minimal Nix derivation that runs Node's built-in test runner
# against the extension's pure logic — no pi, no shell, no VM.
# Catches regressions in the extension's branches (wrong tool, no UI,
# allow, deny, empty command). Runs against the BUILT package output, so
# it exercises exactly the files consumers load.
{ pkgs, inputs, ... }:
pkgs.runCommand "bash-confirm-extension-test"
  {
    src = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-chat-extensions;
    nativeBuildInputs = [ pkgs.nodejs_22 ];
  }
  ''
    cp -r $src/. .
    chmod -R +w .
    node --test bash-confirm.test.mjs
    touch $out
  ''
