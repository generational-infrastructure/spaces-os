import { afterAll, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildRegistry,
  callIntegrationTool,
  type DiscoveredTool,
  discoverTools,
  enabledMtimeMs,
  integrationNames,
  loadDefinition,
  mcpExchange,
  refreshRegistry,
} from "./gateway-core";

const root = mkdtempSync(join(tmpdir(), "gateway-core-test-"));
const servers: Server[] = [];
afterAll(() => {
  for (const s of servers) s.close();
});

/**
 * Minimal NDJSON JSON-RPC (MCP) server: initialize → {}, tools/list → the given
 * tool list, tools/call → onCall(name, args). Mirrors the integration server's
 * wire so the gateway is exercised end to end without a real integration.
 */
function mcpServer(
  sockPath: string,
  opts: {
    tools?: unknown[];
    onCall?: (name: string, args: Record<string, unknown>) => unknown;
  } = {},
): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  const server = createServer((conn) => {
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        if (msg.method === "initialize") {
          conn.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: {} })}\n`,
          );
        } else if (msg.method === "tools/list") {
          conn.write(
            `${JSON.stringify({
              jsonrpc: "2.0",
              id: msg.id,
              result: { tools: opts.tools ?? [] },
            })}\n`,
          );
        } else if (msg.method === "tools/call") {
          const result = opts.onCall?.(
            msg.params.name,
            msg.params.arguments ?? {},
          );
          conn.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result })}\n`,
          );
        }
        // notifications/initialized: no reply.
      }
    });
  });
  servers.push(server);
  server.listen(sockPath, () => resolve());
  return promise;
}

const GH_TOOLS = [
  {
    name: "get_repo",
    description: "Fetch repository metadata",
    inputSchema: {
      type: "object",
      properties: { repo: { type: "string" } },
      required: ["repo"],
    },
  },
  {
    name: "create_issue",
    description: "Create an issue",
    inputSchema: {
      type: "object",
      properties: { repo: { type: "string" }, title: { type: "string" } },
      required: ["repo", "title"],
    },
  },
];

// ---- discoverTools ----------------------------------------------------------

test("discoverTools returns the server's tools with inputSchema as parameters", async () => {
  const sock = join(root, "disc.sock");
  await mcpServer(sock, { tools: GH_TOOLS });
  const tools = await discoverTools(sock);
  expect(tools.map((t) => t.name)).toEqual(["get_repo", "create_issue"]);
  expect(tools[0]!.description).toBe("Fetch repository metadata");
  expect(tools[0]!.parameters).toEqual(GH_TOOLS[0]!.inputSchema);
});

test("discoverTools resolves [] when the socket is unreachable", async () => {
  expect(await discoverTools(join(root, "nope.sock"), undefined, 200)).toEqual(
    [],
  );
});

// ---- buildRegistry ----------------------------------------------------------

function setupManifest(
  name: string,
  defs: Record<
    string,
    { autoRun?: string[]; confirmPreview?: Record<string, string> }
  >,
  enabled: unknown,
): { defsDir: string; enabledPath: string; socketDir: string } {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  for (const [n, def] of Object.entries(defs)) {
    writeFileSync(join(dir, `${n}.json`), JSON.stringify(def));
  }
  const enabledPath = join(dir, "enabled.json");
  writeFileSync(
    enabledPath,
    typeof enabled === "string" ? enabled : JSON.stringify(enabled),
  );
  return { defsDir: dir, enabledPath, socketDir: dir };
}

// A canned discover keyed by socket path, so the registry is built without a
// live server (the MCP wire itself is covered by discoverTools above).
function fakeDiscover(
  bySocket: Record<string, DiscoveredTool[]>,
): (s: string) => Promise<DiscoveredTool[]> {
  return (s) => Promise.resolve(bySocket[s] ?? []);
}

const DISCOVERED: DiscoveredTool[] = GH_TOOLS.map((t) => ({
  name: t.name,
  description: t.description,
  parameters: t.inputSchema,
}));

test("buildRegistry namespaces tools and precomputes the autoRun verdict", async () => {
  const m = setupManifest(
    "reg",
    { github: { autoRun: ["get_repo"] } },
    { integrations: { github: { enabled: true } } },
  );
  const reg = await buildRegistry(
    m,
    fakeDiscover({
      [join(m.socketDir, "spaces-integration-github.sock")]: DISCOVERED,
    }),
  );
  expect([...reg.keys()]).toEqual(["github_get_repo", "github_create_issue"]);
  const get = reg.get("github_get_repo")!;
  expect(get).toMatchObject({
    integration: "github",
    tool: "get_repo",
    socketPath: join(m.socketDir, "spaces-integration-github.sock"),
    autoRun: true,
  });
  // create_issue is not on the allowlist ⇒ confirm-per-call.
  expect(reg.get("github_create_issue")!.autoRun).toBe(false);
});

// ---- loadDefinition: confirmPreview -----------------------------------------

test("loadDefinition parses confirmPreview; absent ⇒ empty map", () => {
  const dir = join(root, "defs-preview");
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "sig.json"),
    JSON.stringify({
      autoRun: ["threads"],
      confirmPreview: { send: "send_preview" },
    }),
  );
  writeFileSync(join(dir, "plain.json"), JSON.stringify({ autoRun: [] }));
  expect(loadDefinition(dir, "sig")!.confirmPreview).toEqual({
    send: "send_preview",
  });
  // A definition without the key ⇒ empty map, never undefined.
  expect(loadDefinition(dir, "plain")!.confirmPreview).toEqual({});
});

test("buildRegistry carries confirmPreview and hides preview tools from the registry", async () => {
  const discovered: DiscoveredTool[] = [
    { name: "send", description: "Send a message", parameters: {} },
    { name: "send_preview", description: "Preview a send", parameters: {} },
    { name: "threads", description: "List threads", parameters: {} },
  ];
  const m = setupManifest(
    "sigreg",
    {
      signal: {
        autoRun: ["threads"],
        confirmPreview: { send: "send_preview" },
      },
    },
    { integrations: { signal: { enabled: true } } },
  );
  const reg = await buildRegistry(
    m,
    fakeDiscover({
      [join(m.socketDir, "spaces-integration-signal.sock")]: discovered,
    }),
  );
  // send_preview is a gateway-only preview target: never registered, so never
  // client-facing (decision 1: "never listed").
  expect([...reg.keys()]).toEqual(["signal_send", "signal_threads"]);
  expect(reg.get("signal_send")!.confirmPreview).toBe("send_preview");
  expect(reg.get("signal_threads")!.confirmPreview).toBeUndefined();
});

test("buildRegistry skips disabled integrations and missing definitions", async () => {
  const m = setupManifest(
    "reg2",
    { github: { autoRun: [] } },
    {
      integrations: {
        github: { enabled: false }, // disabled
        ghost: { enabled: true }, // no ghost.json
      },
    },
  );
  const reg = await buildRegistry(
    m,
    fakeDiscover({
      [join(m.socketDir, "spaces-integration-github.sock")]: DISCOVERED,
    }),
  );
  expect(reg.size).toBe(0);
});

test("buildRegistry yields nothing when enabled.json is unreadable/malformed", async () => {
  const m = setupManifest("reg3", { github: { autoRun: [] } }, "{oops");
  expect((await buildRegistry(m, fakeDiscover({}))).size).toBe(0);
});

// ---- enabledMtimeMs + refreshRegistry (runtime enable/disable) --------------

test("enabledMtimeMs is 0 when absent, positive once the file exists", () => {
  expect(enabledMtimeMs(join(root, "no-such-enabled.json"))).toBe(0);
  const m = setupManifest(
    "mtime",
    { github: { autoRun: [] } },
    { integrations: {} },
  );
  expect(enabledMtimeMs(m.enabledPath)).toBe(statSync(m.enabledPath).mtimeMs);
  expect(enabledMtimeMs(m.enabledPath)).toBeGreaterThan(0);
});

test("refreshRegistry rebuilds only when enabled.json's mtime moves", async () => {
  const m = setupManifest(
    "refresh",
    { github: { autoRun: ["get_repo"] } },
    { integrations: { github: { enabled: true } } },
  );
  const discover = fakeDiscover({
    [join(m.socketDir, "spaces-integration-github.sock")]: DISCOVERED,
  });

  // First refresh (no prior mtime) discovers and registers the tools.
  const first = await refreshRegistry(
    m,
    { mtimeMs: -1, registry: new Map() },
    discover,
  );
  expect(first.rebuilt).toBe(true);
  expect([...first.registry.keys()]).toEqual([
    "github_get_repo",
    "github_create_issue",
  ]);
  expect(first.mtimeMs).toBeGreaterThan(0);

  // Unchanged file ⇒ no re-discovery; the same registry instance is reused.
  const again = await refreshRegistry(
    m,
    { mtimeMs: first.mtimeMs, registry: first.registry },
    discover,
  );
  expect(again.rebuilt).toBe(false);
  expect(again.registry).toBe(first.registry);

  // A runtime disable rewrites enabled.json (new mtime) ⇒ rebuild drops it.
  writeFileSync(
    m.enabledPath,
    JSON.stringify({ integrations: { github: { enabled: false } } }),
  );
  const later = new Date(first.mtimeMs + 5000);
  utimesSync(m.enabledPath, later, later);
  const after = await refreshRegistry(
    m,
    { mtimeMs: first.mtimeMs, registry: first.registry },
    discover,
  );
  expect(after.rebuilt).toBe(true);
  expect(after.registry.size).toBe(0);
});

// ---- integration names ------------------------------------------------------

test("integrationNames lists each enabled integration once", async () => {
  const m = setupManifest(
    "names",
    { github: { autoRun: ["get_repo"] } },
    { integrations: { github: { enabled: true } } },
  );
  const reg = await buildRegistry(
    m,
    fakeDiscover({
      [join(m.socketDir, "spaces-integration-github.sock")]: DISCOVERED,
    }),
  );
  // two discovered tools, one integration ⇒ one name (not one per tool).
  expect(reg.size).toBe(2);
  expect(integrationNames(reg)).toEqual(["github"]);
});

// ---- callIntegrationTool ----------------------------------------------------

test("callIntegrationTool: initialize/initialized/tools-call, text concatenated", async () => {
  const sock = join(root, "happy.sock");
  let seenArgs: Record<string, unknown> = {};
  await mcpServer(sock, {
    onCall: (name, args) => {
      seenArgs = { name, ...args };
      return {
        content: [
          { type: "text", text: "line one" },
          { type: "text", text: "line two" },
        ],
        isError: false,
      };
    },
  });
  const res = await callIntegrationTool(sock, "get_repo", { repo: "o/r" });
  expect(res).toEqual({ text: "line one\nline two", isError: false });
  expect(seenArgs).toEqual({ name: "get_repo", repo: "o/r" });
});

test("callIntegrationTool: server isError surfaces as isError", async () => {
  const sock = join(root, "err.sock");
  await mcpServer(sock, {
    onCall: () => ({
      content: [{ type: "text", text: "boom" }],
      isError: true,
    }),
  });
  const res = await callIntegrationTool(sock, "get_repo", {});
  expect(res).toEqual({ text: "boom", isError: true });
});

test("callIntegrationTool: connection failure resolves unavailable, never throws", async () => {
  const res = await callIntegrationTool(join(root, "nope.sock"), "x", {});
  expect(res.isError).toBe(true);
  expect(res.text).toStartWith("integration unavailable:");
});

test("callIntegrationTool: timeout resolves unavailable", async () => {
  const sock = join(root, "slow.sock");
  const server = createServer(() => {});
  servers.push(server);
  const { promise, resolve } = Promise.withResolvers<void>();
  server.listen(sock, () => resolve());
  await promise;
  const res = await callIntegrationTool(sock, "x", {}, undefined, 200);
  expect(res).toEqual({
    text: "integration unavailable: timeout",
    isError: true,
  });
});

test("callIntegrationTool: abort signal resolves unavailable", async () => {
  const sock = join(root, "abort.sock");
  const server = createServer(() => {});
  servers.push(server);
  const { promise, resolve } = Promise.withResolvers<void>();
  server.listen(sock, () => resolve());
  await promise;
  const ctl = new AbortController();
  const pending = callIntegrationTool(sock, "x", {}, ctl.signal, 5000);
  ctl.abort();
  expect(await pending).toEqual({
    text: "integration unavailable: aborted",
    isError: true,
  });
});

// ---- mcpExchange ------------------------------------------------------------

test("mcpExchange runs the step chain and yields the final reply", async () => {
  const sock = join(root, "exchange.sock");
  await mcpServer(sock, { tools: GH_TOOLS });
  const res = await mcpExchange(
    sock,
    [
      {
        send: [{ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }],
        replyId: 1,
      },
      {
        send: [
          { jsonrpc: "2.0", method: "notifications/initialized" },
          { jsonrpc: "2.0", id: 2, method: "tools/list" },
        ],
        replyId: 2,
      },
    ],
    { timeoutMs: 5000 },
  );
  if (!res.ok) throw new Error(`exchange failed: ${res.reason}`);
  const result = res.reply.result as { tools: unknown[] };
  expect(result.tools).toHaveLength(2);
});

test("mcpExchange resolves a failure result, never rejects", async () => {
  const res = await mcpExchange(
    join(root, "exchange-nope.sock"),
    [{ send: [{ jsonrpc: "2.0", id: 1, method: "initialize" }], replyId: 1 }],
    { timeoutMs: 200 },
  );
  expect(res.ok).toBe(false);
  if (!res.ok) expect(res.reason.length).toBeGreaterThan(0);
});
