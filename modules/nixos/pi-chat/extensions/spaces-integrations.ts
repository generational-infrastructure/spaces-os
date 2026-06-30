// Pi extension: expose the user's enabled agent-integrations as LLM tools.
//
// The integration MCP servers are NOT reachable from the sandbox — their
// sockets are absent from the session's Landlock domain by design. This
// extension is the agent-facing half of the gateway (docs/agent-integrations-
// design.md §9): it registers one forwarding tool per discovered integration
// tool and routes each call back to the trusted supervisor over the rpc pipe,
// where the autoRun allowlist / per-call approval is enforced and the MCP call
// is actually made.
//
// Discovery happens supervisor-side; the supervisor stages the tool list as
// `$PI_CODING_AGENT_DIR/integration-tools.json` before spawning this child. A
// tool call is forwarded as an extension_ui `input` request whose title is the
// sentinel and whose placeholder is JSON `{ integration, tool, args }`; the
// supervisor replies extension_ui_response{ value: JSON `{ text, isError }` }.
//
// Wire contract — MUST match packages/pi-sessiond/integrations.ts
// (INTEGRATION_CALL_TITLE, INTEGRATION_TOOL_SPEC_FILE, and the payload shapes).

import { readFileSync } from "node:fs";
import { join } from "node:path";

const INTEGRATION_CALL_TITLE = "spaces.integration-call";
const INTEGRATION_TOOL_SPEC_FILE = "integration-tools.json";

interface ToolSpecEntry {
  name: string;
  integration: string;
  tool: string;
  label: string;
  description: string;
  parameters: Record<string, unknown>;
}

function loadSpec(): ToolSpecEntry[] {
  const dir = process.env.PI_CODING_AGENT_DIR;
  if (!dir) return [];
  let raw: string;
  try {
    raw = readFileSync(join(dir, INTEGRATION_TOOL_SPEC_FILE), "utf8");
  } catch {
    return []; // no integrations enabled ⇒ no spec ⇒ no tools
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    console.error("[spaces-integrations] failed to parse tool spec:", e);
    return [];
  }
  return Array.isArray(parsed) ? (parsed as ToolSpecEntry[]) : [];
}

const textResult = (text: string, isError: boolean) => ({
  content: [{ type: "text", text }],
  details: {},
  isError,
});

export default function (pi) {
  for (const entry of loadSpec()) {
    pi.registerTool({
      name: entry.name,
      label: entry.label || entry.name,
      description: entry.description,
      parameters: entry.parameters,
      async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
        // The forward is a pipe round-trip; without a client the supervisor
        // cannot enforce approval, so fail closed rather than run unattended.
        if (!ctx.hasUI) {
          return textResult(
            "integration unavailable: no UI to authorize the call",
            true,
          );
        }
        const value = await ctx.ui.input(
          INTEGRATION_CALL_TITLE,
          JSON.stringify({
            integration: entry.integration,
            tool: entry.tool,
            args: params ?? {},
          }),
        );
        if (typeof value !== "string") {
          return textResult("integration call cancelled", true);
        }
        try {
          const reply = JSON.parse(value);
          return textResult(
            typeof reply.text === "string" ? reply.text : "",
            reply.isError === true,
          );
        } catch {
          return textResult("integration unavailable: bad gateway reply", true);
        }
      },
    });
  }
}
