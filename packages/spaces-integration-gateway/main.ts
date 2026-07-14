/**
 * spaces-integration-gateway — the standalone aggregating MCP server
 * (docs/agent-integrations-generic-mcp-design.md). A trusted --user service:
 * it discovers the user's enabled integrations, aggregates their tools onto one
 * MCP surface, enforces the autoRun allowlist + per-call confirm, and forwards
 * to the per-integration sockets. Harnesses connect here (pi via a generic
 * MCP-client extension, MCP-native harnesses via spaces-mcp-connect).
 *
 * Transport: newline-delimited MCP JSON-RPC over the unix socket
 * SPACES_INTEGRATION_GATEWAY_SOCKET. One connection = one
 * session (its own confirm/"session"-grant state). The request-decision logic
 * lives in mcp-server.ts; this file is only the socket transport + env wiring.
 */

import { unlinkSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import {
  callIntegrationTool,
  type Registry,
  refreshRegistry,
} from "./gateway-core";
import { runConfirm } from "./confirm";
import {
  type ConfirmRequest,
  type GatewayDeps,
  handleMcpRequest,
  newSession,
} from "./mcp-server";

// The three discovery inputs (mirror the broker/materialiser layout), the
// confirm command (a JSON argv array), and the listen socket.
const ENABLED = process.env.SPACES_INTEGRATION_GATEWAY_ENABLED ?? "";
const DEFS = process.env.SPACES_INTEGRATION_GATEWAY_DEFS ?? "";
const SOCKETS = process.env.SPACES_INTEGRATION_GATEWAY_SOCKETS ?? "";
const LISTEN_SOCKET = process.env.SPACES_INTEGRATION_GATEWAY_SOCKET ?? "";

function parseArgv(raw: string | undefined): string[] {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v)
      ? v.filter((x): x is string => typeof x === "string")
      : [];
  } catch {
    return [];
  }
}
const CONFIRM_CMD = parseArgv(process.env.SPACES_INTEGRATION_CONFIRM_CMD);

// Lazily rebuilt registry, gated on enabled.json's mtime — a runtime
// enable/disable takes effect on the next request, no restart.
let mtimeMs = -1;
let registry: Registry = new Map();
async function getRegistry(): Promise<Registry> {
  const res = await refreshRegistry(
    { defsDir: DEFS, enabledPath: ENABLED, socketDir: SOCKETS },
    { mtimeMs, registry },
  );
  mtimeMs = res.mtimeMs;
  registry = res.registry;
  return registry;
}

const deps: GatewayDeps = {
  getRegistry,
  confirm: (req: ConfirmRequest) => runConfirm(CONFIRM_CMD, req),
  callTool: callIntegrationTool,
};

function serveConnection(conn: Socket): void {
  const session = newSession();
  let buf = "";
  let draining = false;
  const drain = async () => {
    if (draining) return;
    draining = true;
    try {
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        let req: unknown;
        try {
          req = JSON.parse(line);
        } catch {
          conn.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } })}\n`,
          );
          continue;
        }
        const res = await handleMcpRequest(req, session, deps);
        if (res) conn.write(`${JSON.stringify(res)}\n`);
      }
    } finally {
      draining = false;
    }
  };
  conn.on("data", (chunk) => {
    buf += chunk.toString("utf8");
    void drain();
  });
  conn.on("error", () => {
    // a dropped client connection is normal; the server keeps serving others
  });
}

const server = createServer(serveConnection);
server.on("error", (err) => {
  console.error(`spaces-integration-gateway: ${err}`);
  process.exit(1);
});

// Bind the unix socket path directly. systemd socket activation (LISTEN_FDS) is
// NOT usable: Bun cannot listen on an inherited file descriptor. So the gateway
// is a plain always-on --user service that binds its own socket, like the broker.
if (!LISTEN_SOCKET) {
  console.error(
    "spaces-integration-gateway: no listening socket (set SPACES_INTEGRATION_GATEWAY_SOCKET)",
  );
  process.exit(2);
}
try {
  unlinkSync(LISTEN_SOCKET);
} catch {
  // no stale socket to remove
}
server.listen(LISTEN_SOCKET);
