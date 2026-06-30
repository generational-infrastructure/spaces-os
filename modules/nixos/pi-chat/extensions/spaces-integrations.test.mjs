// Unit test for spaces-integrations.ts pi extension.
//
// Builds a fake ExtensionAPI that captures the tools the extension registers
// from the per-session spec, then drives each tool's execute() through the
// gateway round-trip it performs over ctx.ui.input:
//   - no spec file        → no tools registered
//   - spec present        → one forwarding tool per entry, schema preserved
//   - execute (success)    → forwards { integration, tool, args }, returns text
//   - execute (no UI)      → fails closed, never forwards
//   - execute (cancelled)  → tool error
//   - execute (bad reply)  → tool error
//
// Run with: node --test spaces-integrations.test.mjs
// (Node 22+ strips types from the imported .ts file on the fly.)

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import factory from "./spaces-integrations.ts";

const TITLE = "spaces.integration-call";

const SPEC = [
  {
    name: "github_get_repo",
    integration: "github",
    tool: "get_repo",
    label: "github_get_repo",
    description: "Fetch repository metadata",
    parameters: {
      type: "object",
      properties: { repo: { type: "string" } },
      required: ["repo"],
    },
  },
];

// Set PI_CODING_AGENT_DIR to a temp dir holding the given spec (or none), call
// the factory, and return the tools it registered keyed by name.
function install(t, spec) {
  const dir = mkdtempSync(join(tmpdir(), "spaces-integrations-"));
  if (spec !== undefined) {
    writeFileSync(join(dir, "integration-tools.json"), JSON.stringify(spec));
  }
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = dir;
  t.after(() => {
    if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previous;
    rmSync(dir, { recursive: true, force: true });
  });
  const tools = new Map();
  factory({
    registerTool(def) {
      tools.set(def.name, def);
    },
  });
  return tools;
}

// A ctx whose ui.input records the round-trip and returns a canned value.
function mkCtx({ hasUI = true, value } = {}) {
  const inputs = [];
  return {
    inputs,
    ctx: {
      hasUI,
      ui: {
        input(title, placeholder) {
          inputs.push({ title, placeholder });
          return Promise.resolve(value);
        },
      },
    },
  };
}

test("no spec file registers no tools", (t) => {
  assert.equal(install(t, undefined).size, 0);
});

test("each spec entry becomes a forwarding tool with its schema", (t) => {
  const tools = install(t, SPEC);
  assert.deepEqual([...tools.keys()], ["github_get_repo"]);
  const tool = tools.get("github_get_repo");
  assert.equal(tool.label, "github_get_repo");
  assert.equal(tool.description, "Fetch repository metadata");
  assert.deepEqual(tool.parameters, SPEC[0].parameters);
});

test("execute forwards the call and returns the gateway's text", async (t) => {
  const tools = install(t, SPEC);
  const { inputs, ctx } = mkCtx({
    value: JSON.stringify({ text: "stars: 42", isError: false }),
  });
  const res = await tools
    .get("github_get_repo")
    .execute("id", { repo: "o/r" }, undefined, undefined, ctx);
  assert.equal(inputs.length, 1);
  assert.equal(inputs[0].title, TITLE);
  assert.deepEqual(JSON.parse(inputs[0].placeholder), {
    integration: "github",
    tool: "get_repo",
    args: { repo: "o/r" },
  });
  assert.deepEqual(res, {
    content: [{ type: "text", text: "stars: 42" }],
    details: {},
    isError: false,
  });
});

test("a tool error from the gateway surfaces as isError", async (t) => {
  const tools = install(t, SPEC);
  const { ctx } = mkCtx({
    value: JSON.stringify({ text: "Denied by user.", isError: true }),
  });
  const res = await tools
    .get("github_get_repo")
    .execute("id", { repo: "o/r" }, undefined, undefined, ctx);
  assert.equal(res.isError, true);
  assert.equal(res.content[0].text, "Denied by user.");
});

test("no UI fails closed without forwarding", async (t) => {
  const tools = install(t, SPEC);
  const { inputs, ctx } = mkCtx({ hasUI: false });
  const res = await tools
    .get("github_get_repo")
    .execute("id", { repo: "o/r" }, undefined, undefined, ctx);
  assert.equal(inputs.length, 0, "must not forward without a UI");
  assert.equal(res.isError, true);
});

test("a cancelled prompt is a tool error", async (t) => {
  const tools = install(t, SPEC);
  const { ctx } = mkCtx({ value: undefined });
  const res = await tools
    .get("github_get_repo")
    .execute("id", {}, undefined, undefined, ctx);
  assert.equal(res.isError, true);
});

test("a non-JSON gateway reply is a tool error", async (t) => {
  const tools = install(t, SPEC);
  const { ctx } = mkCtx({ value: "not json" });
  const res = await tools
    .get("github_get_repo")
    .execute("id", {}, undefined, undefined, ctx);
  assert.equal(res.isError, true);
});
