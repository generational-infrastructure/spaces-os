# Design: generic (harness-agnostic) agent integrations

**Status:** in progress. Supersedes the pi-specific gateway shape of
[agent-integrations-design.md](./agent-integrations-design.md) §5.3/§9.1 (the
gateway that lived *inside* `pi-sessiond` and registered each integration tool
as a native pi tool). The isolation model (Landlock domains, the broker, the
per-integration `--user` MCP units, secrets, the manifest, managed profiles) is
**unchanged** — read that document for it. This one records only the change of
*where the gateway lives and how a harness reaches it*.

## Goal

Make the integrations usable by **any** agent harness — pi, Claude Code, Cursor,
Cline, … — not just pi. Concretely:

1. Stop mapping integration tool calls **into pi** (the bundled child extension
   that forwarded over pi's rpc pipe, and the supervisor interception of that
   pipe). That coupling made the whole system pi-only.
2. Expose **one aggregating MCP server** that bundles every *active* (enabled)
   integration. It is an ordinary MCP server: any MCP-capable harness consumes
   it; pi consumes it through a thin generic MCP-client extension (pi ships no
   built-in MCP — "build an extension that adds MCP support").
3. **Confirmations are standalone popups** — a separate GUI process the gateway
   invokes per call, not an event routed into a harness's chat UI.
4. **No integration wiring in any harness-specific GUI.** The settings menu
   (enable / provision / setup) stays, but it already talks straight to the
   broker and is harness-agnostic; the per-call approval cards that lived in the
   pi-chat panel are removed.

The win: the integration logic (discovery, aggregation, allowlist, approval,
file exchange) lives in exactly one portable place. A new harness needs only an
MCP client (built-in, or — for pi — a ~40-line generic adapter) and inherits
every integration.

## What moves, what stays

```
BEFORE (pi-only)                         AFTER (harness-agnostic)

 pi child (sandbox)                        pi child (sandbox)
   spaces-integrations ext                   mcp-client ext ─┐
     registerTool(per tool)                    (generic)     │ MCP over
     call → ctx.ui.input(sentinel)                           │ unix socket
        │ rpc pipe                          Claude/Cursor ────┤
 pi-sessiond (supervisor)                     (native MCP) ───┤
   intercept sentinel                                         ▼
   autoRun / approval  ── approval_request ──►      spaces-integration-gateway
   callIntegrationTool     (pi-chat cards)            (standalone --user MCP server)
        │ MCP                                          discover + aggregate
        ▼                                              autoRun / approval
   integration units (MCP)                             confirm ── SPACES_INTEGRATION_CONFIRM_CMD ──►
                                                            │ MCP        standalone popup (quickshell)
                                                            ▼
                                                       integration units (MCP)   ← UNCHANGED
```

- **Removed:** the gateway inside `pi-sessiond` (`integrations.ts` registry +
  `handleIntegrationCall` + `raiseApproval`/approval ledger), the sentinel
  `extension_ui` interception, the per-session `integration-tools.json`
  staging, the `integration-wire.json` contract, the bundled pi extension's
  tool-forwarding shape, and the `approval_request`/`approval_response` path in
  the pi-chat panel (Reducer/Msg/Bubble/PiSession).
- **Stays:** the broker (`spaces-integrationd`), the per-integration Landlock
  `--user` MCP units + sockets + world-readable definitions, secrets, managed
  profiles, the setup/QR channel, and the pi-chat **settings** section
  (`SettingsWindow` + `IntegrationsBridge`) — it already speaks broker protocol
  only.
- **Kept in `pi-sessiond` but slimmed:** the session Landlock grant of each
  enabled integration's file-exchange shared dir (`sessionSharedDirs`), now
  derived from `enabled.json` directly instead of the gateway registry. File
  exchange is a property of the *agent's* sandbox, independent of who runs the
  gateway.

## Components

### 1. `spaces-integration-gateway` (new, `packages/spaces-integration-gateway/`)

A standalone **aggregating MCP server**, TypeScript on Bun. It is *trusted
mediator* code (like the broker): it runs in its own `--user` service, outside
every agent's Landlock domain, and is the single place that may reach the
per-integration sockets.

- **Inputs** (env, same four the supervisor gateway read):
  `SPACES_INTEGRATION_GATEWAY_ENABLED` (broker `enabled.json`),
  `SPACES_INTEGRATION_GATEWAY_DEFS` (`/etc/spaces-integrations`),
  `SPACES_INTEGRATION_GATEWAY_SOCKETS` (`%t`, where
  `spaces-integration-<name>.sock` live).
- **Listen:** socket activation (`LISTEN_FDS`) or
  `SPACES_INTEGRATION_GATEWAY_SOCKET` — a unix socket at
  `%t/spaces-integration-gateway.sock`.
- **Wire:** MCP JSON-RPC 2.0, newline-delimited (the exact framing the
  integration units already speak), persistent connection: one client sends
  `initialize`, then `tools/list` and many `tools/call` over the same socket.
- **Aggregation:** for each enabled integration, load its definition (`autoRun`,
  `confirmPreview`) and discover its live tools; register one aggregated tool per
  discovered tool, named `<integration>_<tool>`. Preview tools are hidden.
  Rebuilt lazily when `enabled.json`'s mtime moves (runtime enable/disable).
- **Approval (`tools/call`):** if the tool is on `autoRun` **or**
  session-granted (per *connection*), forward immediately; otherwise resolve the
  optional `confirmPreview` context, invoke the confirm command, and act on the
  verdict — `once` (forward this call), `session` (grant for the life of this
  connection, then forward), `deny` (`"Denied by user."`, never forwarded). A
  "session" is one MCP client connection.
- **Ships** `spaces-mcp-connect`: a ~10-line stdio↔unix-socket bridge so an
  MCP-native harness that only speaks stdio can point its `command` at the
  gateway socket.

### 2. Confirm command (the "standalone popup")

The gateway never talks to a harness UI. It spawns a **confirm command**
(`SPACES_INTEGRATION_CONFIRM_CMD`, default = the quickshell popup below) and
waits for a verdict. Contract, deliberately trivial so it is trivially stubbable
in tests and swappable per environment:

- Spawned with two env vars: `SPACES_CONFIRM_REQUEST` = the request JSON
  (`{ integration, tool, toolName, args, context }`) and
  `SPACES_CONFIRM_VERDICT_FILE` = a path to write the verdict to.
- The command writes one token — `once` | `session` | `deny` — to the verdict
  file and exits.
- Missing file, unparseable token, non-zero exit, or timeout ⇒ **`deny`**
  (fail closed).

### 3. `spaces-integration-confirm` (new, `programs/spaces-integration-confirm/`)

The default confirm command: a **standalone quickshell popup** — its own
process, no harness. Reads `SPACES_CONFIRM_REQUEST`, renders a modal popup
(integration, tool, pretty-printed args, and the untrusted `context` preview as
quoted text) with three buttons — *Allow once*, *Allow for this session*,
*Deny* — writes the verdict to `SPACES_CONFIRM_VERDICT_FILE`, and quits. Window
close / no choice ⇒ `deny`. Reuses the approval-card styling extracted from the
old pi-chat `Msg.approval` bubble.

### 4. Generic pi MCP-client extension (`packages/pi-chat-extensions/spaces-integrations.ts`, rewritten)

Since pi ships no MCP, this thin extension *is* pi's MCP client for the gateway.
On load it connects to `SPACES_INTEGRATION_GATEWAY_SOCKET`, runs
`initialize` + `tools/list`, and `registerTool`s each aggregated tool; `execute`
forwards the call as `tools/call` over the socket and returns the result. It
holds **no** approval logic — approval is enforced by the gateway. No
`integration-tools.json`, no sentinel, no `ctx.ui`.

## Security model (unchanged guarantees)

The load-bearing walls are the same (see agent-integrations-design.md §1, §5):

- **Secrets never enter agent context / an integration's private state is
  unreachable by the agent.** The integration `--user` units, their credential
  mounts, and `StateDirectory` are denied by the agent's Landlock domain, and
  the ptrace/mem wall is the sibling-domain rule. The gateway is the only code
  that holds an integration socket.
- **The approval barrier holds.** Effect tools require a human verdict; the
  gateway — not any harness, not the model — decides. Moving the gateway out of
  `pi-sessiond` into its own service does not weaken this: the agent sends
  `tools/call`; the gateway, running in a different domain, chooses whether to
  confirm; the model cannot make it skip.
- **Change vs. before:** the agent now reaches a *gateway socket* directly
  (previously its only integration channel was the rpc pipe). This grants no new
  capability — `tools/list` is the same set and `tools/call` enforces the same
  confirm — but it does mean the agent can speak raw MCP to the gateway. The
  pre-existing "same-uid peer could `connect()` a pathname socket it discovers"
  residual (agent-integrations-poc-plan.md, "Integration-socket peer-auth") is
  unchanged in kind and now also nominally applies to the gateway socket; the
  mitigation (FS non-disclosure + gateway as sole approval point + optional
  `SO_PEERCRED` on the sockets) is tracked in the backlog.

## Testing

- Gateway unit tests (bun): discovery + aggregation; `tools/list` payload;
  `tools/call` autoRun→forward, non-autoRun→confirm(stub)→{once,session,deny},
  session grant scoped per connection, deny never forwards, `confirmPreview`
  context, unknown tool, `initialize` handshake.
- Confirm-command protocol test: verdict-file round-trip; fail-closed on
  missing/invalid/non-zero.
- `spaces-mcp-connect` bridge test: bytes pass both directions.
- Generic pi extension test (mjs): against a stub gateway socket, registers the
  advertised tools and forwards a call.
- Cheap headless checks: `checks/spaces-integration-gateway-unit` (bun) and
  `checks/spaces-integration-gateway-e2e` (the real gateway binary against a
  stub integration socket + a stub confirm command, end to end);
  `checks/spaces-integration-confirm` drives the standalone popup's verdict
  contract headless.

The old in-supervisor VM test (`checks/integration-poc-machine`) was removed
with the in-pi gateway. A full-VM e2e for the standalone-gateway topology (the
secret path, the Landlock wall, the cross-user matrix, file exchange) is
**backlogged** — see `backlog/agent-integrations-generic-mcp.md`.
