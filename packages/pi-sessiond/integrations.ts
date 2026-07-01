/**
 * Integrations gateway (docs/agent-integrations-design.md §9) — the
 * supervisor-side mediator between the sandboxed pi runtime and the per-user
 * integration MCP servers. The agent never reaches an integration socket (it is
 * absent from the session Landlock domain); instead a bundled child extension
 * (spaces-integrations.ts) registers one forwarding tool per discovered tool and
 * routes each call back over the rpc pipe, where the supervisor enforces the
 * autoRun allowlist / per-call approval and speaks MCP to the integration.
 *
 * This module is the pure, unit-testable half: discover the enabled
 * integrations' tools (initialize + tools/list), build the tool registry, stage
 * the per-session child spec, and speak the NDJSON JSON-RPC (MCP) wire. main.ts
 * owns the side-channel interception, the approval prompt, and session grants.
 */

import { readFileSync, statSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { join } from "node:path";

// ---- wire contract (shared with the bundled child extension + the panel) ----
// The bundled extension (spaces-integrations.ts) is materialised into a separate
// store path and cannot import this module, so it duplicates these literals —
// keep the two in sync.
//
// The child forwards a tool call as an extension_ui `input` request whose title
// is this sentinel and whose placeholder is JSON `{ integration, tool, args }`;
// the supervisor replies extension_ui_response{ value: JSON `{ text, isError }` }.
export const INTEGRATION_CALL_TITLE = "spaces.integration-call";
// The per-session spec the child extension reads from its agent dir (HOME).
export const INTEGRATION_TOOL_SPEC_FILE = "integration-tools.json";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// Integration / tool names build socket paths and tool ids; only plain idents.
const NAME_RE = /^[a-zA-Z0-9_-]+$/;

// ---- manifest / enabled state -----------------------------------------------

// Enabled integrations from the broker's enabled.json
// (`{ integrations: { <name>: { enabled: true } } }`) — names only; the
// definition JSON carries everything else. Any read/parse failure ⇒ no
// integrations (never throws — a broken file must not block session creation).
export function loadEnabled(enabledPath: string): string[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(enabledPath, "utf8"));
  } catch (err) {
    console.error(`integrations: cannot read ${enabledPath}: ${err}`);
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
  return { autoRun };
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
  piName: string; // LLM-facing tool name: `${integration}_${tool}`
  integration: string;
  tool: string;
  description: string;
  parameters: Record<string, unknown>;
  socketPath: string;
  autoRun: boolean; // on the manifest allowlist ⇒ runs without a prompt
}

export type Registry = Map<string, RegistryEntry>; // keyed by piName

/**
 * MCP discovery on a fresh connection: initialize → notifications/initialized →
 * tools/list, NDJSON JSON-RPC 2.0. Resolves the server's tool list (name +
 * description + inputSchema → parameters); NEVER rejects — any failure resolves
 * `[]`, so a down or broken integration simply contributes no tools.
 */
export function discoverTools(
  socketPath: string,
  signal?: AbortSignal,
  timeoutMs = 10000,
): Promise<DiscoveredTool[]> {
  const { promise, resolve } = Promise.withResolvers<DiscoveredTool[]>();

  const sock = createConnection(socketPath);
  let settled = false;
  const finish = (tools: DiscoveredTool[]) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
    sock.destroy();
    resolve(tools);
  };

  const timer = setTimeout(() => finish([]), timeoutMs);
  const onAbort = () => finish([]);
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();

  sock.on("error", () => finish([]));
  sock.on("close", () => finish([]));

  const writeLine = (msg: unknown) => {
    sock.write(`${JSON.stringify(msg)}\n`);
  };

  sock.on("connect", () => {
    writeLine({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "pi-sessiond", version: "0" },
      },
    });
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
        finish([]);
        return;
      }
      if (!isRecord(msg)) continue;
      if (msg.id === 1) {
        // initialize done → notify, then list.
        writeLine({ jsonrpc: "2.0", method: "notifications/initialized" });
        writeLine({ jsonrpc: "2.0", id: 2, method: "tools/list" });
      } else if (msg.id === 2) {
        const result = isRecord(msg.result) ? msg.result : {};
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
        finish(tools);
        return;
      }
    }
  });

  return promise;
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
    const tools = await discover(socketPath);
    for (const t of tools) {
      if (!NAME_RE.test(t.name)) continue;
      const piName = `${name}_${t.name}`;
      registry.set(piName, {
        piName,
        integration: name,
        tool: t.name,
        description: t.description,
        parameters: t.parameters,
        socketPath,
        autoRun: def.autoRun.includes(t.name),
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
// Lets the supervisor discover integrations lazily at session create so a
// runtime enable/disable takes effect on the next new chat — not only after a
// daemon restart. Never throws (buildRegistry swallows its own failures), so a
// broken integration can't block session creation.
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

// The per-integration file-exchange dirs to fold into the agent session's
// Landlock rw allowlist (design §9.4 step 6): one <sharedBase>/<name> per
// enabled integration — the SAME dir the integration unit grants itself rw, so
// clone_to_workspace populates it and the agent edits the tree with its native
// file tools. Empty base or no integrations ⇒ none, so the grant appears only
// when an integration is enabled.
export function sessionSharedDirs(
  registry: Registry,
  sharedBase: string,
): string[] {
  if (!sharedBase) return [];
  return integrationNames(registry).map((name) => join(sharedBase, name));
}

// ---- per-session child spec -------------------------------------------------

// The child-facing spec: the LLM-callable shape, no autoRun (approval is
// enforced supervisor-side). The bundled extension reads this and
// registerTool()s each entry.
export interface ToolSpecEntry {
  name: string; // piName
  integration: string;
  tool: string;
  label: string;
  description: string;
  parameters: Record<string, unknown>;
}

export function toolSpec(registry: Registry): ToolSpecEntry[] {
  return [...registry.values()].map((e) => ({
    name: e.piName,
    integration: e.integration,
    tool: e.tool,
    label: e.piName,
    description: e.description,
    parameters: e.parameters,
  }));
}

// Stage the per-session spec the child extension reads from its agent dir (HOME).
export function writeSessionToolSpec(
  registry: Registry,
  agentDir: string,
): void {
  writeFileSync(
    join(agentDir, INTEGRATION_TOOL_SPEC_FILE),
    JSON.stringify(toolSpec(registry)),
  );
}

/**
 * One tool call = one fresh connection (the "MCP wire"): initialize →
 * notifications/initialized → tools/call, NDJSON JSON-RPC 2.0 over the unix
 * socket. Resolves with the concatenated text content; NEVER rejects —
 * connection/timeout/abort failures resolve `integration unavailable: <reason>`
 * with isError so the agent sees a failed tool result, not a crashed turn.
 */
export function callIntegrationTool(
  socketPath: string,
  tool: string,
  args: Record<string, unknown>,
  signal?: AbortSignal,
  timeoutMs = 60000,
): Promise<{ text: string; isError: boolean }> {
  const { promise, resolve } = Promise.withResolvers<{
    text: string;
    isError: boolean;
  }>();

  const sock = createConnection(socketPath);
  let settled = false;
  const finish = (result: { text: string; isError: boolean }) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    signal?.removeEventListener("abort", onAbort);
    sock.destroy();
    resolve(result);
  };
  const unavailable = (reason: string) =>
    finish({ text: `integration unavailable: ${reason}`, isError: true });

  const timer = setTimeout(() => unavailable("timeout"), timeoutMs);
  const onAbort = () => unavailable("aborted");
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();

  sock.on("error", (err) => unavailable(err.message));
  sock.on("close", () => unavailable("connection closed"));

  const writeLine = (msg: unknown) => {
    sock.write(`${JSON.stringify(msg)}\n`);
  };

  sock.on("connect", () => {
    writeLine({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "pi-sessiond", version: "0" },
      },
    });
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
        unavailable("bad reply (not JSON)");
        return;
      }
      if (!isRecord(msg)) continue;
      if (msg.id === 1) {
        // initialize done → fire the notification, then the actual call.
        writeLine({ jsonrpc: "2.0", method: "notifications/initialized" });
        writeLine({
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: { name: tool, arguments: args },
        });
      } else if (msg.id === 2) {
        if (isRecord(msg.error)) {
          finish({ text: String(msg.error.message ?? "error"), isError: true });
          return;
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
        finish({ text, isError: result.isError === true });
        return;
      }
    }
  });

  return promise;
}
