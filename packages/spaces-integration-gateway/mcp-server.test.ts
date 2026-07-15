import { expect, test } from "bun:test";
import type { Registry, RegistryEntry } from "./gateway-core";
import {
  advertisedTools,
  type ConfirmRequest,
  type GatewayDeps,
  type GrantStore,
  handleMcpRequest,
  newSession,
  SESSION_GRANT_TTL_MS,
  type Verdict,
} from "./mcp-server";

function reg(entries: Partial<RegistryEntry>[]): Registry {
  const m: Registry = new Map();
  for (const e of entries) {
    const full: RegistryEntry = {
      piName: `${e.integration}_${e.tool}`,
      integration: e.integration ?? "x",
      tool: e.tool ?? "t",
      description: e.description ?? "",
      parameters: e.parameters ?? { type: "object", properties: {} },
      socketPath:
        e.socketPath ?? `/run/spaces-integration-${e.integration}.sock`,
      autoRun: e.autoRun ?? false,
      confirmPreview: e.confirmPreview,
    };
    m.set(full.piName, full);
  }
  return m;
}

interface CallRecord {
  socketPath: string;
  tool: string;
  args: Record<string, unknown>;
}

function makeDeps(opts: {
  registry: Registry;
  verdict?: Verdict;
  // Per-tool call results (keyed by the RAW tool name); default success text.
  results?: Record<string, { text: string; isError: boolean }>;
}): {
  deps: GatewayDeps;
  calls: CallRecord[];
  confirms: ConfirmRequest[];
} {
  const calls: CallRecord[] = [];
  const confirms: ConfirmRequest[] = [];
  const deps: GatewayDeps = {
    getRegistry: () => Promise.resolve(opts.registry),
    confirm: (req) => {
      confirms.push(req);
      return Promise.resolve(opts.verdict ?? "deny");
    },
    callTool: (socketPath, tool, args) => {
      calls.push({ socketPath, tool, args });
      const r = opts.results?.[tool];
      return Promise.resolve(r ?? { text: `${tool}-ok`, isError: false });
    },
  };
  return { deps, calls, confirms };
}

const call = (name: string, args: Record<string, unknown> = {}) => ({
  jsonrpc: "2.0",
  id: 7,
  method: "tools/call",
  params: { name, arguments: args },
});

// ---- advertisedTools --------------------------------------------------------

test("advertisedTools maps registry entries to MCP tool descriptors", () => {
  const r = reg([
    {
      integration: "github",
      tool: "get_repo",
      description: "Fetch repo",
      parameters: { type: "object", properties: { repo: { type: "string" } } },
    },
  ]);
  expect(advertisedTools(r)).toEqual([
    {
      name: "github_get_repo",
      description: "Fetch repo",
      inputSchema: { type: "object", properties: { repo: { type: "string" } } },
    },
  ]);
});

// ---- initialize / tools/list / notifications --------------------------------

test("initialize returns protocol version, serverInfo, and tools capability", async () => {
  const { deps } = makeDeps({ registry: reg([]) });
  const res = await handleMcpRequest(
    { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    newSession(),
    deps,
  );
  expect(res?.id).toBe(1);
  const result = res?.result as Record<string, unknown>;
  expect(result.protocolVersion).toBe("2025-03-26");
  expect(result.capabilities).toEqual({ tools: {} });
  expect((result.serverInfo as Record<string, unknown>).name).toBe(
    "spaces-integration-gateway",
  );
});

test("notifications/initialized owes no reply", async () => {
  const { deps } = makeDeps({ registry: reg([]) });
  const res = await handleMcpRequest(
    { jsonrpc: "2.0", method: "notifications/initialized" },
    newSession(),
    deps,
  );
  expect(res).toBeNull();
});

test("tools/list returns the aggregated advertised tools", async () => {
  const r = reg([
    { integration: "github", tool: "get_repo" },
    { integration: "signal", tool: "send" },
  ]);
  const { deps } = makeDeps({ registry: r });
  const res = await handleMcpRequest(
    { jsonrpc: "2.0", id: 2, method: "tools/list" },
    newSession(),
    deps,
  );
  const result = res?.result as { tools: { name: string }[] };
  expect(result.tools.map((t) => t.name)).toEqual([
    "github_get_repo",
    "signal_send",
  ]);
});

test("an unknown method resolves a JSON-RPC method-not-found error", async () => {
  const { deps } = makeDeps({ registry: reg([]) });
  const res = await handleMcpRequest(
    { jsonrpc: "2.0", id: 3, method: "resources/list" },
    newSession(),
    deps,
  );
  expect((res?.error as Record<string, unknown>).code).toBe(-32601);
});

// ---- tools/call: autoRun ----------------------------------------------------

test("an autoRun tool forwards immediately with no confirm", async () => {
  const r = reg([{ integration: "github", tool: "get_repo", autoRun: true }]);
  const { deps, calls, confirms } = makeDeps({ registry: r });
  const res = await handleMcpRequest(
    call("github_get_repo", { repo: "o/r" }),
    newSession(),
    deps,
  );
  expect(confirms).toHaveLength(0);
  expect(calls).toEqual([
    {
      socketPath: r.get("github_get_repo")!.socketPath,
      tool: "get_repo",
      args: { repo: "o/r" },
    },
  ]);
  const result = res?.result as {
    content: { text: string }[];
    isError: boolean;
  };
  expect(result.content[0]!.text).toBe("get_repo-ok");
  expect(result.isError).toBe(false);
});

// ---- tools/call: confirm verdicts -------------------------------------------

test("a non-autoRun tool confirmed 'once' forwards but does not persist the grant", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, calls, confirms } = makeDeps({ registry: r, verdict: "once" });
  const session = newSession();
  await handleMcpRequest(
    call("github_create_issue", { title: "x" }),
    session,
    deps,
  );
  await handleMcpRequest(
    call("github_create_issue", { title: "y" }),
    session,
    deps,
  );
  // Confirmed each time (no persisted grant), forwarded each time.
  expect(confirms).toHaveLength(2);
  expect(confirms[0]).toMatchObject({
    integration: "github",
    tool: "create_issue",
    toolName: "github_create_issue",
    args: { title: "x" },
  });
  expect(calls).toHaveLength(2);
});

test("a non-autoRun tool confirmed 'session' skips the prompt on later calls", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, calls, confirms } = makeDeps({
    registry: r,
    verdict: "session",
  });
  const session = newSession();
  await handleMcpRequest(
    call("github_create_issue", { title: "x" }),
    session,
    deps,
  );
  await handleMcpRequest(
    call("github_create_issue", { title: "y" }),
    session,
    deps,
  );
  expect(confirms).toHaveLength(1); // only the first call prompted
  expect(calls).toHaveLength(2); // both forwarded
});

test("a session grant is scoped to its own session, not shared", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, confirms } = makeDeps({ registry: r, verdict: "session" });
  await handleMcpRequest(call("github_create_issue"), newSession(), deps);
  await handleMcpRequest(call("github_create_issue"), newSession(), deps);
  // A fresh session re-prompts — the grant did not leak across sessions.
  expect(confirms).toHaveLength(2);
});

test("a denied tool is never forwarded and returns the denial", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, calls, confirms } = makeDeps({ registry: r, verdict: "deny" });
  const res = await handleMcpRequest(
    call("github_create_issue"),
    newSession(),
    deps,
  );
  expect(confirms).toHaveLength(1);
  expect(calls).toHaveLength(0); // the integration is never called
  const result = res?.result as {
    content: { text: string }[];
    isError: boolean;
  };
  expect(result.content[0]!.text).toBe("Denied by user.");
  expect(result.isError).toBe(true);
});

test("an unknown tool errors without confirming or forwarding", async () => {
  const { deps, calls, confirms } = makeDeps({ registry: reg([]) });
  const res = await handleMcpRequest(call("ghost_tool"), newSession(), deps);
  expect(confirms).toHaveLength(0);
  expect(calls).toHaveLength(0);
  const result = res?.result as {
    content: { text: string }[];
    isError: boolean;
  };
  expect(result.isError).toBe(true);
  expect(result.content[0]!.text).toContain("unknown tool");
});

// ---- tools/call: confirmPreview ---------------------------------------------

test("confirmPreview output is fetched and passed as the confirm context", async () => {
  const r = reg([
    { integration: "signal", tool: "send", confirmPreview: "send_preview" },
  ]);
  const { deps, calls, confirms } = makeDeps({
    registry: r,
    verdict: "once",
    results: {
      send_preview: { text: "To: Bob\nHi", isError: false },
      send: { text: "sent", isError: false },
    },
  });
  await handleMcpRequest(
    call("signal_send", { to: "bob", body: "Hi" }),
    newSession(),
    deps,
  );
  // Preview tool called with the same args, before the real tool.
  expect(calls[0]).toMatchObject({
    tool: "send_preview",
    args: { to: "bob", body: "Hi" },
  });
  expect(calls[1]).toMatchObject({ tool: "send" });
  expect(confirms[0]!.context).toBe("To: Bob\nHi");
});

test("a failed confirmPreview fails closed: surfaces the error, no prompt, no send", async () => {
  const r = reg([
    { integration: "signal", tool: "send", confirmPreview: "send_preview" },
  ]);
  const { deps, calls, confirms } = makeDeps({
    registry: r,
    verdict: "once",
    results: {
      send_preview: { text: "preview boom", isError: true },
      send: { text: "sent", isError: false },
    },
  });
  const res = await handleMcpRequest(
    call("signal_send", {}),
    newSession(),
    deps,
  );
  expect(confirms).toHaveLength(0); // never prompted
  expect(calls.map((c) => c.tool)).toEqual(["send_preview"]); // send never reached
  const result = res?.result as {
    content: { text: string }[];
    isError: boolean;
  };
  expect(result.isError).toBe(true);
  expect(result.content[0]!.text).toBe("preview boom");
});

// ---- spaces/session: per-process shared grant keys --------------------------

const bindKey = (key: unknown) => ({
  jsonrpc: "2.0",
  method: "spaces/session",
  params: { key },
});

test("spaces/session is a notification: it owes no reply", async () => {
  const { deps } = makeDeps({ registry: reg([]) });
  const store: GrantStore = new Map();
  const res = await handleMcpRequest(bindKey("k1"), newSession(), {
    ...deps,
    grantStore: store,
  });
  expect(res).toBeNull();
});

test("two sessions sharing one key share a session grant", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, calls, confirms } = makeDeps({
    registry: r,
    verdict: "session",
  });
  const store: GrantStore = new Map();
  const d = { ...deps, grantStore: store };

  const a = newSession();
  await handleMcpRequest(bindKey("shared"), a, d);
  await handleMcpRequest(call("github_create_issue", { title: "x" }), a, d);

  const b = newSession();
  await handleMcpRequest(bindKey("shared"), b, d);
  await handleMcpRequest(call("github_create_issue", { title: "y" }), b, d);

  expect(confirms).toHaveLength(1); // only session A prompted; B inherited the grant
  expect(calls).toHaveLength(2); // both forwarded
});

test("distinct keys keep grants isolated", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, confirms } = makeDeps({ registry: r, verdict: "session" });
  const store: GrantStore = new Map();
  const d = { ...deps, grantStore: store };

  const a = newSession();
  await handleMcpRequest(bindKey("keyA"), a, d);
  await handleMcpRequest(call("github_create_issue"), a, d);

  const b = newSession();
  await handleMcpRequest(bindKey("keyB"), b, d);
  await handleMcpRequest(call("github_create_issue"), b, d);

  expect(confirms).toHaveLength(2); // different key ⇒ B still prompts
});

test("a bad key (empty / oversized / non-string) does not bind a shared set", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps, confirms } = makeDeps({ registry: r, verdict: "session" });
  const store: GrantStore = new Map();
  const d = { ...deps, grantStore: store };

  for (const bad of ["", "x".repeat(129), 42, null]) {
    const s = newSession();
    await handleMcpRequest(bindKey(bad), s, d);
    await handleMcpRequest(call("github_create_issue"), s, d);
  }
  // each session kept its own private set ⇒ each prompted independently
  expect(confirms).toHaveLength(4);
  expect(store.size).toBe(0);
});

test("binding sweeps entries idle beyond the TTL", async () => {
  const r = reg([{ integration: "github", tool: "create_issue" }]);
  const { deps } = makeDeps({ registry: r, verdict: "session" });
  const store: GrantStore = new Map();
  let t = 1_000_000;
  const d = { ...deps, grantStore: store, now: () => t };

  await handleMcpRequest(bindKey("stale"), newSession(), d);
  expect(store.has("stale")).toBe(true);

  t += SESSION_GRANT_TTL_MS + 1; // let "stale" age past the TTL
  await handleMcpRequest(bindKey("fresh"), newSession(), d);
  expect(store.has("stale")).toBe(false); // swept lazily on the new binding
  expect(store.has("fresh")).toBe(true);
});
