# Unit check: the standalone aggregating MCP gateway
# (docs/agent-integrations-generic-mcp-design.md). Runs the gateway's bun unit
# suites — the discovery/registry core, the MCP request handler (autoRun /
# per-connection session grants / confirm verdicts / confirmPreview fail-closed),
# the confirm-command verdict protocol, and the stdio↔socket bridge. No kernel,
# no sockets to a real integration. ~1s.
{ pkgs, ... }:
pkgs.runCommand "spaces-integration-gateway-unit-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/spaces-integration-gateway;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./gateway-core.test.ts ./mcp-server.test.ts ./confirm.test.ts ./connect.test.ts
    touch $out
  ''
