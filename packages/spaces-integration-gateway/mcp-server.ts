/**
 * The harness-facing MCP server: turns the aggregated registry into one MCP
 * surface (initialize / tools/list / tools/call), enforces the autoRun
 * allowlist and per-connection session grants, and runs the confirm command for
 * everything else. Transport-agnostic — mcpExchange/socket plumbing lives in
 * gateway-core + main.ts; this module is the pure request handler so the
 * approval decisions are unit-testable without a socket.
 */

import {
  callIntegrationTool,
  type Registry,
  type RegistryEntry,
} from "./gateway-core";

const PROTOCOL_VERSION = "2025-03-26";
// A hung preview must not stall the approval gate: cap it well under the 60s
// default so a stuck preview fails closed quickly.
const PREVIEW_TIMEOUT_MS = 10000;

export type Verdict = "once" | "session" | "deny";

// The args-bound confirm payload handed to the confirm command. Binds to the
// concrete arguments the gateway will forward (design §5.3: the human sees
// exactly what runs). `context` is a confirmPreview tool's untrusted output.
export interface ConfirmRequest {
  integration: string;
  tool: string;
  toolName: string;
  args: Record<string, unknown>;
  context?: string;
}

// Per-connection state. A "session" is one MCP client connection; a `session`
// grant lives only as long as that connection.
export interface GatewaySession {
  grants: Set<string>;
}

export interface GatewayDeps {
  getRegistry: () => Promise<Registry>;
  confirm: (req: ConfirmRequest) => Promise<Verdict>;
  // Defaults to the real MCP call over the integration socket; injected in tests.
  callTool?: (
    socketPath: string,
    tool: string,
    args: Record<string, unknown>,
    signal?: AbortSignal,
    timeoutMs?: number,
  ) => Promise<{ text: string; isError: boolean }>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export function newSession(): GatewaySession {
  return { grants: new Set() };
}

// The MCP tools/list payload for the aggregated registry: the namespaced name,
// the integration's description, and its (untrusted, presentation-only) schema.
export function advertisedTools(registry: Registry): {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}[] {
  return [...registry.values()].map((e) => ({
    name: e.piName,
    description: e.description,
    inputSchema: e.parameters,
  }));
}

// Enforce the allowlist / session grant / confirm, then forward. A Deny (or a
// failed confirmPreview) never reaches the integration. Returns the tool-result
// text + isError, never throws.
async function callWithApproval(
  entry: RegistryEntry,
  args: Record<string, unknown>,
  session: GatewaySession,
  deps: GatewayDeps,
): Promise<{ text: string; isError: boolean }> {
  const callTool = deps.callTool ?? callIntegrationTool;
  if (entry.autoRun || session.grants.has(entry.piName)) {
    return callTool(entry.socketPath, entry.tool, args);
  }

  // Resolve the untrusted approval context (design §5.3). Fails CLOSED: a
  // preview error surfaces as the tool result and no prompt is raised.
  let context: string | undefined;
  if (entry.confirmPreview) {
    const preview = await callTool(
      entry.socketPath,
      entry.confirmPreview,
      args,
      undefined,
      PREVIEW_TIMEOUT_MS,
    );
    if (preview.isError) return { text: preview.text, isError: true };
    context = preview.text;
  }

  const verdict = await deps.confirm({
    integration: entry.integration,
    tool: entry.tool,
    toolName: entry.piName,
    args,
    context,
  });
  if (verdict === "deny") return { text: "Denied by user.", isError: true };
  if (verdict === "session") session.grants.add(entry.piName);
  return callTool(entry.socketPath, entry.tool, args);
}

async function handleToolCall(
  params: unknown,
  session: GatewaySession,
  deps: GatewayDeps,
): Promise<Record<string, unknown>> {
  const p = isRecord(params) ? params : {};
  const name = typeof p.name === "string" ? p.name : "";
  const args = isRecord(p.arguments) ? p.arguments : {};
  const entry = (await deps.getRegistry()).get(name);
  if (!entry) {
    return {
      content: [{ type: "text", text: `unknown tool: ${name}` }],
      isError: true,
    };
  }
  const out = await callWithApproval(entry, args, session, deps);
  return {
    content: [{ type: "text", text: out.text }],
    isError: out.isError,
  };
}

/**
 * Handle one JSON-RPC request on a connection; returns the response object, or
 * null when no reply is owed (a notification). Never throws — a malformed
 * request yields a JSON-RPC error.
 */
export async function handleMcpRequest(
  request: unknown,
  session: GatewaySession,
  deps: GatewayDeps,
): Promise<Record<string, unknown> | null> {
  const req = isRecord(request) ? request : {};
  const method = typeof req.method === "string" ? req.method : "";
  const id = req.id;
  const isNotification = !("id" in req);

  let result: Record<string, unknown>;
  if (method === "initialize") {
    result = {
      protocolVersion: PROTOCOL_VERSION,
      serverInfo: { name: "spaces-integration-gateway", version: "0" },
      capabilities: { tools: {} },
    };
  } else if (method === "notifications/initialized") {
    return null;
  } else if (method === "tools/list") {
    result = { tools: advertisedTools(await deps.getRegistry()) };
  } else if (method === "tools/call") {
    result = await handleToolCall(req.params, session, deps);
  } else {
    if (isNotification) return null;
    return {
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: `method not found: ${method}` },
    };
  }

  if (isNotification) return null;
  return { jsonrpc: "2.0", id, result };
}
