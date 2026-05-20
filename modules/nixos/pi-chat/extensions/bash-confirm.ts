// Pi extension: gate every `bash` tool call behind a user confirmation.
//
// Hooks pi's `tool_call` event. For bash invocations, it asks the user via
// ctx.ui.confirm — in RPC mode (driven by the noctalia chat plugin), that
// translates to an extension_ui_request{method=confirm} event on stdout.
// The plugin renders Allow/Deny buttons; the user's choice is plumbed
// back as extension_ui_response{confirmed}.
//
// If no UI is available (print mode, no client connected) the call is
// blocked, never silently allowed.

export default function (pi) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return undefined;
    if (!ctx.hasUI) {
      return {
        block: true,
        reason: "bash confirmation required but no UI is available",
      };
    }
    const command = String(event.input?.command ?? "").trim();
    if (command === "") return undefined;
    const ok = await ctx.ui.confirm("Run shell command?", command);
    if (!ok) return { block: true, reason: "denied by user" };
    return undefined;
  });
}
