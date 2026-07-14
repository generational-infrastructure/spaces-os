# End-to-end check: the REAL aggregating gateway binary
# (packages/spaces-integration-gateway) over its unix socket, against a stub
# integration MCP server + a stub confirm command. Proves the transport, socket
# binding, lazy discovery, the autoRun allowlist, and the confirm-command spawn
# (docs/agent-integrations-generic-mcp-design.md). ~seconds; no VM, no harness.
{ inputs, pkgs, ... }:
let
  gateway = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.spaces-integration-gateway;
in
pkgs.runCommand "spaces-integration-gateway-e2e-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    set -euo pipefail
    export TMPDIR=$(mktemp -d)
    export HOME=$TMPDIR
    ${pkgs.python3}/bin/python3 ${./driver.py} ${pkgs.lib.getExe gateway}
    touch $out
  ''
