# Unit test for the spaces-integrations pi extension
# (packages/pi-chat-extensions/spaces-integrations.ts).
#
# Builds a minimal Nix derivation that runs Node's built-in test runner against
# the extension's pure logic — no pi, no gateway, no VM. Catches regressions in
# how it connects to the standalone gateway over SPACES_INTEGRATION_GATEWAY_SOCKET,
# registers a forwarding tool per aggregated tool from tools/list, and forwards
# each call as a tools/call over that connection. Runs against the BUILT package
# output. The gateway's own half is checks/spaces-integration-gateway-{unit,e2e}.
{ pkgs, inputs, ... }:
pkgs.runCommand "spaces-integrations-extension-test"
  {
    src = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-chat-extensions;
    nativeBuildInputs = [ pkgs.nodejs_22 ];
  }
  ''
    cp -r $src/. .
    chmod -R +w .
    node --test spaces-integrations.test.mjs
    touch $out
  ''
