// Unit test for bash-confirm.ts pi extension.
//
// Builds a fake ExtensionAPI that captures the tool_call handler the
// extension registers, then drives that handler through each branch:
//   - non-bash tool   → undefined (allow)
//   - no UI           → blocked
//   - empty command   → undefined (no prompt)
//   - confirm allow   → undefined, prompt seen
//   - confirm deny    → blocked, prompt seen
//
// Run with: node --test bash-confirm.test.mjs
// (Node 22+ strips types from the imported .ts file on the fly.)

import { test } from "node:test";
import assert from "node:assert/strict";

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
