// Pi extension: expose the user's enabled agent-integrations as LLM tools by
// consuming the standalone aggregating gateway over MCP
// (docs/agent-integrations-generic-mcp-design.md §4).
//
// Pi ships no MCP client, so this thin extension *is* pi's MCP client for the
// gateway: on load it connects to SPACES_INTEGRATION_GATEWAY_SOCKET, runs
// initialize + tools/list, and registers one forwarding tool per aggregated
// tool. execute() forwards a tools/call over the SAME persistent connection. It
// also declares a per-pi-process session key (spaces/session) so "allow for this
// session" grants are shared across this process's connection(s) and survive a
// reconnect for the process's lifetime. All approval logic lives in the gateway
// — this holds none.
//
// The gateway is a separate --user service outside the agent's Landlock domain;
// the model cannot make it skip a confirm. A down/absent gateway ⇒ zero tools
// (never blocks pi startup).

import { randomUUID } from "node:crypto";
import { createConnection, type Socket } from "node:net";

// One random key per pi process: grants made under it are shared across this
// process's gateway connection(s) and die with the process (design §3).
const SESSION_KEY = randomUUID();

// Cap the startup handshake so a slow/wedged gateway degrades to "no tools"
// instead of stalling pi startup (the factory is awaited before pi is ready).
const STARTUP_TIMEOUT_MS = 20000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

const textResult = (text: string, isError: boolean) => ({
  content: [{ type: "text", text }],
  details: {},
  isError,
});

interface AdvertisedTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

// A persistent MCP client over the gateway unix socket. One connection per pi
// session; requests are correlated by numeric id. Never throws — a dead
// connection resolves calls to a tool error.
class GatewayClient {
  private buf = "";
  private nextId = 1;
  private alive = true;
  private readonly pending = new Map<
    number,
    (msg: Record<string, unknown>) => void
  >();
  private readonly sock: Socket;

  private constructor(sock: Socket) {
    this.sock = sock;
    // Don't keep pi alive on the integration connection alone.
    sock.unref();
    sock.on("data", (chunk) => this.onData(chunk));
    sock.on("close", () => this.onClose());
    sock.on("error", () => this.onClose());
  }

  static connect(
    path: string,
    timeoutMs = 5000,
  ): Promise<GatewayClient | null> {
    const { promise, resolve } = Promise.withResolvers<GatewayClient | null>();
    const sock = createConnection(path);
    const timer = setTimeout(() => {
      sock.destroy();
      resolve(null);
    }, timeoutMs);
    sock.once("connect", () => {
      clearTimeout(timer);
      resolve(new GatewayClient(sock));
    });
    sock.once("error", () => {
      clearTimeout(timer);
      resolve(null);
    });
    return promise;
  }

  private onClose(): void {
    this.alive = false;
    for (const resolve of this.pending.values()) {
      resolve({ error: { message: "gateway connection closed" } });
    }
    this.pending.clear();
  }

  private onData(chunk: Buffer): void {
    this.buf += chunk.toString("utf8");
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let msg: unknown;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (isRecord(msg) && typeof msg.id === "number") {
        const resolve = this.pending.get(msg.id);
        if (resolve) {
          this.pending.delete(msg.id);
          resolve(msg);
        }
      }
    }
  }

  private notify(method: string, params?: Record<string, unknown>): void {
    if (!this.alive) return;
    const msg =
      params === undefined
        ? { jsonrpc: "2.0", method }
        : { jsonrpc: "2.0", method, params };
    this.sock.write(`${JSON.stringify(msg)}\n`);
  }

  private request(
    method: string,
    params: Record<string, unknown>,
    timeoutMs = 60000,
  ): Promise<Record<string, unknown>> {
    if (!this.alive) {
      return Promise.resolve({ error: { message: "gateway unavailable" } });
    }
    const id = this.nextId++;
    const { promise, resolve } =
      Promise.withResolvers<Record<string, unknown>>();
    const timer = setTimeout(() => {
      this.pending.delete(id);
      resolve({ error: { message: "gateway timeout" } });
    }, timeoutMs);
    this.pending.set(id, (msg) => {
      clearTimeout(timer);
      resolve(msg);
    });
    this.sock.write(
      `${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`,
    );
    return promise;
  }

  async listTools(): Promise<AdvertisedTool[]> {
    // Declare this process's session key before initialize, so a `session`
    // grant persists across reconnects for the pi process's lifetime.
    this.notify("spaces/session", { key: SESSION_KEY });
    await this.request(
      "initialize",
      {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "pi", version: "0" },
      },
      STARTUP_TIMEOUT_MS,
    );
    this.notify("notifications/initialized");
    const reply = await this.request("tools/list", {}, STARTUP_TIMEOUT_MS);
    const result = isRecord(reply.result) ? reply.result : {};
    const list = Array.isArray(result.tools) ? result.tools : [];
    const tools: AdvertisedTool[] = [];
    for (const t of list) {
      if (!isRecord(t) || typeof t.name !== "string") continue;
      tools.push({
        name: t.name,
        description: typeof t.description === "string" ? t.description : "",
        inputSchema: isRecord(t.inputSchema)
          ? t.inputSchema
          : { type: "object", properties: {} },
      });
    }
    return tools;
  }

  async callTool(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ text: string; isError: boolean }> {
    const reply = await this.request("tools/call", { name, arguments: args });
    if (isRecord(reply.error)) {
      return { text: String(reply.error.message ?? "error"), isError: true };
    }
    const result = isRecord(reply.result) ? reply.result : {};
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
}

export default async function (pi) {
  const path = process.env.SPACES_INTEGRATION_GATEWAY_SOCKET;
  if (!path) return; // no gateway configured ⇒ no integration tools
  const client = await GatewayClient.connect(path);
  if (!client) return; // gateway down ⇒ no tools (never blocks pi startup)
  for (const tool of await client.listTools()) {
    pi.registerTool({
      name: tool.name,
      label: tool.name,
      description: tool.description,
      parameters: tool.inputSchema,
      async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
        const res = await client.callTool(tool.name, params ?? {});
        return textResult(res.text, res.isError);
      },
    });
  }
}
