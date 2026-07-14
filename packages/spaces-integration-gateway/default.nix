{ pkgs, ... }:
# spaces-integration-gateway — the standalone aggregating MCP server
# (docs/agent-integrations-generic-mcp-design.md). A --user service that
# discovers the user's enabled integrations, aggregates their tools onto one MCP
# surface, enforces the autoRun allowlist + a standalone confirm command, and
# forwards to the per-integration sockets. Any MCP-capable harness consumes it.
#
# Pure Bun + node stdlib (net/fs/child_process): no node_modules, no pi SDK —
# cheap to build and to pull onto an integration host. Ships two binaries:
#   - spaces-integration-gateway: the server (main.ts);
#   - spaces-mcp-connect: a stdio↔socket bridge (connect.ts) for MCP-native
#     harnesses that only speak stdio.
let
  src = pkgs.runCommandLocal "spaces-integration-gateway-src" { } ''
    mkdir -p "$out"
    cp ${./gateway-core.ts} "$out/gateway-core.ts"
    cp ${./mcp-server.ts} "$out/mcp-server.ts"
    cp ${./confirm.ts} "$out/confirm.ts"
    cp ${./connect.ts} "$out/connect.ts"
    cp ${./main.ts} "$out/main.ts"
  '';
  connect = pkgs.writeShellScriptBin "spaces-mcp-connect" ''
    exec ${pkgs.bun}/bin/bun ${src}/connect.ts "$@"
  '';
in
(pkgs.writeShellScriptBin "spaces-integration-gateway" ''
  exec ${pkgs.bun}/bin/bun ${src}/main.ts "$@"
'').overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit connect;
    };
    meta = (old.meta or { }) // {
      description = "Standalone aggregating MCP server bundling spaces agent integrations";
      mainProgram = "spaces-integration-gateway";
    };
  })
