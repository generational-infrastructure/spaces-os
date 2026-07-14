/**
 * Aggregating-gateway core (docs/agent-integrations-generic-mcp-design.md) —
 * the pure, unit-testable half of the standalone integration gateway. It knows
 * how to:
 *   - read the broker's enabled.json + the world-readable definitions,
 *   - discover each enabled integration's live tools (initialize + tools/list),
 *   - build the aggregated tool registry (namespaced `<integration>_<tool>`),
 *   - speak the NDJSON JSON-RPC (MCP) wire to an integration socket.
 *
 * mcp-server.ts owns the harness-facing MCP server, per-connection session
 * grants, and the confirm command. This module holds no transport server and no
 * pi/harness specifics: it is portable mediator logic.
 */

import { readFileSync, statSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// Integration / tool names build socket paths and tool ids; only plain idents.
const NAME_RE = /^[a-zA-Z0-9_-]+$/;

// ---- manifest / enabled state -----------------------------------------------

// Enabled integrations from the broker's enabled.json
// (`{ integrations: { <name>: { enabled: true } } }`) — names only; the
// definition JSON carries everything else. Any read/parse failure ⇒ no
// integrations (never throws — a broken file must not block the gateway).
export function loadEnabled(enabledPath: string): string[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(enabledPath, "utf8"));
  } catch (err) {
    // A missing enabled.json = no integrations configured (the common case);
    // only a malformed/unreadable file is worth logging.
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") {
      console.error(`integrations: cannot read ${enabledPath}: ${err}`);
    }
    return [];
  }
  if (!isRecord(parsed) || !isRecord(parsed.integrations)) return [];
  const names: string[] = [];
  for (const [name, state] of Object.entries(parsed.integrations)) {
    if (!isRecord(state) || state.enabled !== true) continue;
    if (!NAME_RE.test(name)) {
      console.error(
        `integrations: skipping bad integration name ${JSON.stringify(name)}`,
      );
      continue;
    }
    names.push(name);
  }
  return names;
}

// The world-readable definition JSON (no secrets). The gateway only needs the
// autoRun allowlist; the panel/broker read the rest (description, secrets…).
export interface IntegrationDef {
  autoRun: string[];
  // Per-tool preview map: a confirm tool name → the gateway-only preview tool
  // it calls (same socket, same args) before raising the approval prompt, whose
  // text becomes the approval's untrusted `context`. Absent/empty ⇒ no
  // previews. Preview tools are never client-facing (buildRegistry drops them).
  confirmPreview: Record<string, string>;
}

export function loadDefinition(
  defsDir: string,
  name: string,
): IntegrationDef | undefined {
  let def: unknown;
  try {
    def = JSON.parse(readFileSync(join(defsDir, `${name}.json`), "utf8"));
  } catch (err) {
    console.error(`integrations: cannot read definition for ${name}: ${err}`);
    return undefined;
  }
  if (!isRecord(def)) return undefined;
  const autoRun = Array.isArray(def.autoRun)
    ? def.autoRun.filter((t): t is string => typeof t === "string")
    : [];
  const confirmPreview: Record<string, string> = {};
  if (isRecord(def.confirmPreview)) {
    for (const [tool, preview] of Object.entries(def.confirmPreview)) {
      if (typeof preview === "string") confirmPreview[tool] = preview;
    }
  }
  return { autoRun, confirmPreview };
}

// ---- runtime discovery + registry -------------------------------------------

export interface DiscoveredTool {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

// One registered, forwardable tool: a discovered MCP tool bound to its
// integration + socket, with the autoRun verdict precomputed from the manifest.
export interface RegistryEntry {
  piName: string; // aggregated MCP tool name: `${integration}_${tool}`
  integration: string;
  tool: string;
  description: string;
  parameters: Record<string, unknown>;
  socketPath: string;
  autoRun: boolean; // on the manifest allowlist ⇒ runs without a prompt
  // This entry's confirmPreview tool (see IntegrationDef.confirmPreview).
  confirmPreview?: string;
}

export type Registry = Map<string, RegistryEntry>; // keyed by piName

// ---- MCP wire primitive -------------------------------------------------------

// One step of an NDJSON JSON-RPC exchange: write `send`, then wait for the
// reply whose id is `replyId` before the next step (or the final resolve).
export interface McpStep {
  send: unknown[];
  replyId: number;
}

export type McpExchangeResult =
  | { ok: true; reply: Record<string, unknown> }
  | { ok: false; reason: string };

/**
 * One MCP exchange on a fresh unix-socket connection (the "MCP wire"), NDJSON
 * JSON-RPC 2.0: write step 0's messages on connect; each time the current
 * step's `replyId` reply arrives, write the next step's messages; the LAST
 * step's reply resolves the exchange. Replies with other ids are skipped.
 * NEVER rejects — connect/timeout/abort/parse failures resolve
 * `{ ok: false, reason }` — and the socket is always destroyed on settle.
 */
export function mcpExchange(
  socketPath: string,
  steps: McpStep[],
  opts: { signal?: AbortSignal; timeoutMs: number },
): Promise<McpExchangeResult> {
  const { signal, timeoutMs } = opts;
  const { promise, resolve } = Promise.withResolvers<McpExchangeResult>();

  const sock = createConnection(socketPath);
  let settled = false;
  const finish = (result: McpExchangeResult) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
    sock.destroy();
    resolve(result);
  };
  const fail = (reason: string) => finish({ ok: false, reason });

  const timer = setTimeout(() => fail("timeout"), timeoutMs);
  const onAbort = () => fail("aborted");
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();

  sock.on("error", (err) => fail(err.message));
  sock.on("close", () => fail("connection closed"));

  const writeLine = (msg: unknown) => {
    sock.write(`${JSON.stringify(msg)}\n`);
  };

  let step = 0;
  sock.on("connect", () => {
    for (const msg of steps[step]?.send ?? []) writeLine(msg);
  });

  let buf = "";
  sock.on("data", (chunk) => {
    buf += chunk.toString("utf8");
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg: unknown;
      try {
        msg = JSON.parse(line);
      } catch {
        fail("bad reply (not JSON)");
        return;
      }
      if (!isRecord(msg) || msg.id !== steps[step]?.replyId) continue;
      step += 1;
      if (step === steps.length) {
        finish({ ok: true, reply: msg });
        return;
      }
      for (const m of steps[step]!.send) writeLine(m);
    }
  });

  return promise;
}

// The fixed MCP handshake both discovery and tool calls perform: initialize
// (id 1) → notifications/initialized + the caller's request (id 2).
const handshake = (request: Record<string, unknown>): McpStep[] => [
  {
    send: [
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "spaces-integration-gateway", version: "0" },
        },
      },
    ],
    replyId: 1,
  },
  {
    send: [
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, ...request },
    ],
    replyId: 2,
  },
];

/**
 * MCP discovery on a fresh connection: the handshake, then tools/list.
 * Resolves the server's tool list (name + description + inputSchema →
 * parameters); NEVER rejects — any failure resolves `[]`, so a down or broken
 * integration simply contributes no tools.
 */
export async function discoverTools(
  socketPath: string,
  signal?: AbortSignal,
  timeoutMs = 10000,
): Promise<DiscoveredTool[]> {
  const res = await mcpExchange(
    socketPath,
    handshake({ method: "tools/list" }),
    { signal, timeoutMs },
  );
  if (!res.ok) return [];
  const result = isRecord(res.reply.result) ? res.reply.result : {};
  const list = Array.isArray(result.tools) ? result.tools : [];
  const tools: DiscoveredTool[] = [];
  for (const t of list) {
    if (!isRecord(t) || typeof t.name !== "string") continue;
    tools.push({
      name: t.name,
      description: typeof t.description === "string" ? t.description : "",
      parameters: isRecord(t.inputSchema)
        ? t.inputSchema
        : { type: "object", properties: {} },
    });
  }
  return tools;
}

/**
 * Build the gateway's tool registry: for each enabled integration, load its
 * definition (autoRun) and discover its live tools, registering one forwardable
 * entry per tool keyed by `${integration}_${tool}`. The discover function is
 * injectable for tests. A failed/empty discovery contributes nothing.
 */
export async function buildRegistry(
  opts: { defsDir: string; enabledPath: string; socketDir: string },
  discover: (socketPath: string) => Promise<DiscoveredTool[]> = (s) =>
    discoverTools(s),
): Promise<Registry> {
  const registry: Registry = new Map();
  for (const name of loadEnabled(opts.enabledPath)) {
    const def = loadDefinition(opts.defsDir, name);
    if (!def) continue;
    // Socket by the materialiser's unit convention (spaces-integrations/lib.nix
    // unitName): %t/spaces-integration-<name>.sock. socketDir is the daemon's
    // %t ($XDG_RUNTIME_DIR), shared with the integration units' user manager.
    const socketPath = join(opts.socketDir, `spaces-integration-${name}.sock`);
    // Preview tools get no registry entry (see IntegrationDef.confirmPreview).
    const previewTools = new Set(Object.values(def.confirmPreview));
    const tools = await discover(socketPath);
    const toolNames = new Set(tools.map((t) => t.name));
    for (const preview of previewTools) {
      if (!toolNames.has(preview))
        console.error(
          `integrations: ${name} confirmPreview tool ${JSON.stringify(preview)} not discovered`,
        );
    }
    for (const t of tools) {
      if (!NAME_RE.test(t.name)) continue;
      if (previewTools.has(t.name)) continue;
      const piName = `${name}_${t.name}`;
      registry.set(piName, {
        piName,
        integration: name,
        tool: t.name,
        description: t.description,
        parameters: t.parameters,
        socketPath,
        autoRun: def.autoRun.includes(t.name),
        confirmPreview: def.confirmPreview[t.name],
      });
    }
  }
  return registry;
}

// enabled.json's mtime in ms, or 0 when absent/unstat-able. The gateway gates
// re-discovery on this: the broker rewrites enabled.json on every runtime
// enable/disable, so a moved mtime is the signal that the enabled set changed.
export function enabledMtimeMs(enabledPath: string): number {
  try {
    return statSync(enabledPath).mtimeMs;
  } catch {
    return 0;
  }
}

export interface RegistryRefresh {
  registry: Registry;
  mtimeMs: number;
  rebuilt: boolean;
}

// Rebuild the registry only when enabled.json changed since `since.mtimeMs`.
// Lets the gateway discover integrations lazily so a runtime enable/disable
// takes effect on the next request — not only after a restart. Never throws
// (buildRegistry swallows its own failures), so a broken integration can't
// wedge the gateway.
export async function refreshRegistry(
  opts: { defsDir: string; enabledPath: string; socketDir: string },
  since: { mtimeMs: number; registry: Registry },
  discover?: (socketPath: string) => Promise<DiscoveredTool[]>,
): Promise<RegistryRefresh> {
  const mtimeMs = enabledMtimeMs(opts.enabledPath);
  if (mtimeMs === since.mtimeMs) {
    return { registry: since.registry, mtimeMs, rebuilt: false };
  }
  const registry = await buildRegistry(opts, discover);
  return { registry, mtimeMs, rebuilt: true };
}

// The distinct integration names behind the registry's tools (stable order) —
// the enabled set, since every entry carries its integration. One name even
// when an integration exposes several tools.
export function integrationNames(registry: Registry): string[] {
  const seen = new Set<string>();
  for (const e of registry.values()) seen.add(e.integration);
  return [...seen];
}

/**
 * One tool call = one fresh connection: the handshake, then tools/call.
 * Resolves with the concatenated text content; NEVER rejects —
 * connection/timeout/abort failures resolve `integration unavailable: <reason>`
 * with isError so the harness sees a failed tool result, not a crashed turn.
 */
export async function callIntegrationTool(
  socketPath: string,
  tool: string,
  args: Record<string, unknown>,
  signal?: AbortSignal,
  timeoutMs = 60000,
): Promise<{ text: string; isError: boolean }> {
  const res = await mcpExchange(
    socketPath,
    handshake({
      method: "tools/call",
      params: { name: tool, arguments: args },
    }),
    { signal, timeoutMs },
  );
  if (!res.ok) {
    return { text: `integration unavailable: ${res.reason}`, isError: true };
  }
  const msg = res.reply;
  if (isRecord(msg.error)) {
    return { text: String(msg.error.message ?? "error"), isError: true };
  }
  const result = isRecord(msg.result) ? msg.result : {};
  const content = Array.isArray(result.content) ? result.content : [];
  const text = content
    .filter(
      (c): c is { type: string; text: string } =>
        isRecord(c) && c.type === "text" && typeof c.text === "string",
    )
    .map((c) => c.text)
    .join("\n");
  return { text, isError: result.isError === true };
}
