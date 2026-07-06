// Pi extension: gate every `bash` tool call behind a user confirmation.
//
// Hooks pi's `tool_call` event. For bash invocations, it asks the user via
// ctx.ui.confirm — in RPC mode (driven by the pi-chat Quickshell panel),
// that translates to an extension_ui_request{method=confirm} event on
// stdout. The panel renders Allow/Deny buttons; the user's choice is plumbed
// back as extension_ui_response{confirmed}.
//
// If no UI is available (print mode, no client connected) the call is
// blocked, never silently allowed.
//
// Allowlist:
// Commands matching any regex listed in `${PI_CODING_AGENT_DIR}/bash-confirm.json`
// (`{ "allowPatterns": ["regex1", ...] }`) skip the prompt entirely — useful
// for declaratively-trusted helpers like `skill-config` whose input/output
// never carry attacker-controlled payloads.
// Malformed regex entries are dropped on load (warned on stderr); missing
// file means "no allowlist", preserving the prompt-everything default.

import { readFileSync } from "node:fs";
import { join } from "node:path";

function loadAllowPatterns(): RegExp[] {
  const dir = process.env.PI_CODING_AGENT_DIR;
  if (!dir) return [];
  let raw: string;
  try {
    raw = readFileSync(join(dir, "bash-confirm.json"), "utf8");
  } catch {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    console.error("[bash-confirm] failed to parse bash-confirm.json:", e);
    return [];
  }
  const patterns = (parsed as { allowPatterns?: unknown })?.allowPatterns;
  if (!Array.isArray(patterns)) return [];
  const compiled: RegExp[] = [];
  for (const src of patterns) {
    if (typeof src !== "string") continue;
    try {
      compiled.push(new RegExp(src));
    } catch (e) {
      console.error(
        "[bash-confirm] dropping malformed regex",
        JSON.stringify(src),
        ":",
        e,
      );
    }
  }
  return compiled;
}

export default function (pi) {
  const allowPatterns = loadAllowPatterns();

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return undefined;
    const command = String(event.input?.command ?? "").trim();
    if (command === "") return undefined;
    if (allowPatterns.some((re) => re.test(command))) return undefined;
    if (!ctx.hasUI) {
      return {
        block: true,
        reason: "bash confirmation required but no UI is available",
      };
    }
    const ok = await ctx.ui.confirm("Run shell command?", command);
    if (!ok) return { block: true, reason: "denied by user" };
    return undefined;
  });
}
