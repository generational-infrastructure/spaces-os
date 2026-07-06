// Unit test for bash-confirm.ts pi extension.
//
// Builds a fake ExtensionAPI that captures the tool_call handler the
// extension registers, then drives that handler through each branch:
//   - non-bash tool   → undefined (allow)
//   - no UI           → blocked
//   - empty command   → undefined (no prompt)
//   - confirm allow   → undefined, prompt seen
//   - confirm deny    → blocked, prompt seen
//   - allowlist match → undefined, no prompt (even without UI)
//
// Run with: node --test bash-confirm.test.mjs
// (Node 22+ strips types from the imported .ts file on the fly.)

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import factory from "./bash-confirm.ts";

function installExtension() {
	let handler;
	const pi = {
		on(event, fn) {
			assert.equal(event, "tool_call", "extension hooked unexpected event");
			handler = fn;
		},
	};
	factory(pi);
	assert.ok(handler, "extension did not register a tool_call handler");
	return handler;
}

function mkCtx({ hasUI = true, confirmResult = true } = {}) {
	const prompts = [];
	return {
		prompts,
		ctx: {
			hasUI,
			ui: {
				confirm(title, message) {
					prompts.push({ title, message });
					return Promise.resolve(confirmResult);
				},
			},
		},
	};
}

function withAgentDir(t, config) {
	const dir = mkdtempSync(join(tmpdir(), "pi-bash-confirm-"));
	writeFileSync(join(dir, "bash-confirm.json"), JSON.stringify(config));
	const previous = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = dir;
	t.after(() => {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		rmSync(dir, { recursive: true, force: true });
	});
	return dir;
}

test("non-bash tool calls pass through untouched", async () => {
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	const result = await handler({ toolName: "edit", input: { path: "a" } }, ctx);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, []);
});

test("blocks bash when no UI is available", async () => {
	const handler = installExtension();
	const { ctx, prompts } = mkCtx({ hasUI: false });
	const result = await handler({ toolName: "bash", input: { command: "echo hi" } }, ctx);
	assert.deepEqual(result, {
		block: true,
		reason: "bash confirmation required but no UI is available",
	});
	assert.deepEqual(prompts, []);
});

test("empty command is allowed without prompting", async () => {
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	const result = await handler({ toolName: "bash", input: { command: "   " } }, ctx);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, []);
});

test("allows bash on user confirm", async () => {
	const handler = installExtension();
	const { ctx, prompts } = mkCtx({ confirmResult: true });
	const result = await handler({ toolName: "bash", input: { command: "ls /" } }, ctx);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, [{ title: "Run shell command?", message: "ls /" }]);
});

test("blocks bash on user deny", async () => {
	const handler = installExtension();
	const { ctx, prompts } = mkCtx({ confirmResult: false });
	const result = await handler({ toolName: "bash", input: { command: "rm -rf /" } }, ctx);
	assert.deepEqual(result, { block: true, reason: "denied by user" });
	assert.deepEqual(prompts, [{ title: "Run shell command?", message: "rm -rf /" }]);
});

test("falsy/missing command input is treated as empty", async () => {
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	const result = await handler({ toolName: "bash", input: {} }, ctx);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, []);
});

test("allowlist regex match skips the prompt entirely", async (t) => {
	withAgentDir(t, { allowPatterns: ["^skill-config(\\s|$)"] });
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	const result = await handler(
		{ toolName: "bash", input: { command: "skill-config list calendar" } },
		ctx,
	);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, []);
});

test("allowlist match bypasses confirmation even without UI", async (t) => {
	withAgentDir(t, { allowPatterns: ["^skill-config(\\s|$)"] });
	const handler = installExtension();
	const { ctx, prompts } = mkCtx({ hasUI: false });
	const result = await handler(
		{ toolName: "bash", input: { command: "skill-config schema calendar" } },
		ctx,
	);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, []);
});

test("allowlist patterns that do not match still prompt", async (t) => {
	withAgentDir(t, { allowPatterns: ["^skill-config(\\s|$)"] });
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	const result = await handler({ toolName: "bash", input: { command: "rm -rf /" } }, ctx);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, [{ title: "Run shell command?", message: "rm -rf /" }]);
});

test("partial-match patterns require explicit anchors", async (t) => {
	// Sanity check: a pattern without `^` matches anywhere, so commands
	// that simply mention `skill-config` are allowed. This documents the
	// behaviour authors need to be aware of when authoring patterns.
	withAgentDir(t, { allowPatterns: ["skill-config"] });
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	const result = await handler(
		{ toolName: "bash", input: { command: "echo skill-config" } },
		ctx,
	);
	assert.equal(result, undefined);
	assert.deepEqual(prompts, []);
});

test("malformed regex is dropped without crashing the extension", async (t) => {
	withAgentDir(t, { allowPatterns: ["^(unterminated", "^skill-config(\\s|$)"] });
	const handler = installExtension();
	const { ctx, prompts } = mkCtx();
	// Still allows skill-config (the valid pattern is kept).
	const ok = await handler(
		{ toolName: "bash", input: { command: "skill-config list" } },
		ctx,
	);
	assert.equal(ok, undefined);
	assert.deepEqual(prompts, []);
});

test("missing config file leaves existing behaviour intact", async () => {
	const previous = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(tmpdir(), "pi-bash-confirm-does-not-exist");
	try {
		const handler = installExtension();
		const { ctx, prompts } = mkCtx();
		const result = await handler(
			{ toolName: "bash", input: { command: "skill-config list" } },
			ctx,
		);
		assert.equal(result, undefined);
		assert.deepEqual(prompts, [
			{ title: "Run shell command?", message: "skill-config list" },
		]);
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
	}
});
