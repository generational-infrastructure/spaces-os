import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildRegistry,
  callIntegrationTool,
  type DiscoveredTool,
  discoverTools,
  INTEGRATION_TOOL_SPEC_FILE,
  toolSpec,
  writeSessionToolSpec,
} from "./integrations";

const root = mkdtempSync(join(tmpdir(), "integrations-test-"));
const servers: Server[] = [];
afterAll(() => {
  for (const s of servers) s.close();
});

/**
 * Minimal NDJSON JSON-RPC (MCP) server: initialize → {}, tools/list → the given
 * tool list, tools/call → onCall(name, args). Mirrors the integration server's
 * wire so the gateway is exercised end to end without pi.
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
  defs: Record<string, { autoRun?: string[] }>,
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
    fakeDiscover({ [join(m.socketDir, "github.sock")]: DISCOVERED }),
  );
  expect([...reg.keys()]).toEqual(["github_get_repo", "github_create_issue"]);
  const get = reg.get("github_get_repo")!;
  expect(get).toMatchObject({
    integration: "github",
    tool: "get_repo",
    socketPath: join(m.socketDir, "github.sock"),
    autoRun: true,
  });
  // create_issue is not on the allowlist ⇒ confirm-per-call.
  expect(reg.get("github_create_issue")!.autoRun).toBe(false);
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
    fakeDiscover({ [join(m.socketDir, "github.sock")]: DISCOVERED }),
  );
  expect(reg.size).toBe(0);
});

test("buildRegistry yields nothing when enabled.json is unreadable/malformed", async () => {
  const m = setupManifest("reg3", { github: { autoRun: [] } }, "{oops");
  expect((await buildRegistry(m, fakeDiscover({}))).size).toBe(0);
});

// ---- session spec -----------------------------------------------------------

test("writeSessionToolSpec stages the LLM-facing shape without autoRun", async () => {
  const m = setupManifest(
    "spec",
    { github: { autoRun: ["get_repo"] } },
    { integrations: { github: { enabled: true } } },
  );
  const reg = await buildRegistry(
    m,
    fakeDiscover({ [join(m.socketDir, "github.sock")]: DISCOVERED }),
  );
  const agentDir = mkdtempSync(join(tmpdir(), "agentdir-"));
  writeSessionToolSpec(reg, agentDir);
  const spec = JSON.parse(
    readFileSync(join(agentDir, INTEGRATION_TOOL_SPEC_FILE), "utf8"),
  );
  expect(spec).toEqual(toolSpec(reg));
  expect(spec[0]).toEqual({
    name: "github_get_repo",
    integration: "github",
    tool: "get_repo",
    label: "github_get_repo",
    description: "Fetch repository metadata",
    parameters: GH_TOOLS[0]!.inputSchema,
  });
  // The child spec never carries the allowlist — approval is supervisor-side.
  expect(spec[0]).not.toHaveProperty("autoRun");
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
