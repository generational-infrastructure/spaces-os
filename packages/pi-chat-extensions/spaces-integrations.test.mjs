// Unit test for spaces-integrations.ts — the generic MCP-client pi extension
// (docs/agent-integrations-generic-mcp-design.md §4). It connects to the
// standalone gateway over SPACES_INTEGRATION_GATEWAY_SOCKET, runs
// initialize + tools/list, and registers one forwarding tool per aggregated
// tool; execute() forwards a tools/call over the same connection.
//
//   - no socket env       → no tools registered (never blocks pi startup)
//   - gateway unreachable  → no tools registered
//   - tools/list           → one forwarding tool per entry, schema preserved
//   - execute (success)    → forwards tools/call, returns the text
//   - execute (isError)    → tool error surfaced
//   - two calls            → forwarded over one persistent connection
//
// Run with: node --test spaces-integrations.test.mjs
// (Node 22+ strips types from the imported .ts file on the fly.)

import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import factory from "./spaces-integrations.ts";

const TOOLS = [
  {
    name: "github_get_repo",
    description: "Fetch repository metadata",
    inputSchema: {
      type: "object",
      properties: { repo: { type: "string" } },
      required: ["repo"],
    },
  },
];

// A stub gateway MCP server: initialize → {}, tools/list → TOOLS (or given),
// tools/call → onCall(name, args). Records each call.
function stubGateway(sock, { tools = TOOLS, onCall } = {}) {
  const calls = [];
  const server = createServer((conn) => {
    conn.unref(); // don't let a stub connection keep node --test alive
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        const msg = JSON.parse(line);
        if (msg.method === "initialize") {
          conn.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { capabilities: { tools: {} } } })}\n`,
          );
        } else if (msg.method === "tools/list") {
          conn.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: { tools } })}\n`,
          );
        } else if (msg.method === "tools/call") {
          calls.push({ name: msg.params.name, args: msg.params.arguments ?? {} });
          const r = onCall
            ? onCall(msg.params.name, msg.params.arguments ?? {})
            : { content: [{ type: "text", text: `${msg.params.name}-ok` }], isError: false };
          conn.write(
            `${JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: r })}\n`,
          );
        }
        // notifications/initialized: no id, no reply.
      }
    });
  });
  server.calls = calls;
  return server;
}

async function install(t, opts = {}) {
  const dir = mkdtempSync(join(tmpdir(), "gw-"));
  const sock = join(dir, "gw.sock");
  let server = null;
  if (!opts.noGateway) {
    server = stubGateway(sock, opts);
    const listening = Promise.withResolvers();
    server.listen(sock, () => listening.resolve());
    await listening.promise;
  }
  const prev = process.env.SPACES_INTEGRATION_GATEWAY_SOCKET;
  if (opts.noEnv) delete process.env.SPACES_INTEGRATION_GATEWAY_SOCKET;
  else process.env.SPACES_INTEGRATION_GATEWAY_SOCKET = sock;

  const tools = new Map();
  await factory({ registerTool: (d) => tools.set(d.name, d) });

  t.after(() => {
    if (server) server.close();
    if (prev === undefined) delete process.env.SPACES_INTEGRATION_GATEWAY_SOCKET;
    else process.env.SPACES_INTEGRATION_GATEWAY_SOCKET = prev;
  });
  return { tools, server };
}

test("no gateway socket env registers no tools", async (t) => {
  const { tools } = await install(t, { noEnv: true });
  assert.equal(tools.size, 0);
});

test("an unreachable gateway registers no tools (never blocks startup)", async (t) => {
  const { tools } = await install(t, { noGateway: true });
  assert.equal(tools.size, 0);
});

test("each advertised tool becomes a forwarding tool with its schema", async (t) => {
  const { tools } = await install(t);
  assert.deepEqual([...tools.keys()], ["github_get_repo"]);
  assert.deepEqual(tools.get("github_get_repo").parameters, TOOLS[0].inputSchema);
});

test("execute forwards the tools/call and returns the gateway text", async (t) => {
  const { tools, server } = await install(t);
  const res = await tools.get("github_get_repo").execute("id", { repo: "o/r" });
  assert.deepEqual(server.calls, [{ name: "github_get_repo", args: { repo: "o/r" } }]);
  assert.equal(res.content[0].text, "github_get_repo-ok");
  assert.equal(res.isError, false);
});

test("a gateway tool error surfaces as isError", async (t) => {
  const { tools } = await install(t, {
    onCall: () => ({ content: [{ type: "text", text: "Denied by user." }], isError: true }),
  });
  const res = await tools.get("github_get_repo").execute("id", {});
  assert.equal(res.isError, true);
  assert.equal(res.content[0].text, "Denied by user.");
});

test("multiple calls are forwarded over one persistent connection", async (t) => {
  const { tools, server } = await install(t);
  await tools.get("github_get_repo").execute("id", { repo: "a" });
  await tools.get("github_get_repo").execute("id", { repo: "b" });
  assert.equal(server.calls.length, 2);
});
