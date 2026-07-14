# Backlog: generic (harness-agnostic) agent integrations

Open decisions dropped here rather than guessed, while making the integrations
harness-agnostic (see `docs/agent-integrations-generic-mcp-design.md`). Each is
non-blocking for the core deliverable (the standalone aggregating MCP server +
standalone confirm popups + generic pi consumption); each changes reach or
polish and wants a human call.

## 1. Transport for MCP-native harnesses (stdio bridge vs. Streamable HTTP)

The gateway serves newline-delimited MCP JSON-RPC over a **unix socket**. The
MCP spec's standard transports are **stdio** and **Streamable HTTP**. Shipped:
`spaces-mcp-connect`, a stdio↔socket bridge, so any stdio MCP client
(`command = spaces-mcp-connect`) reaches the gateway.

**Decide:** also serve **Streamable HTTP** (for HTTP-only clients, and for
remote/networked harnesses)? On localhost TCP (universally supported, but any
same-uid process can reach it) or an HTTP-over-unix-socket (needs client
support)? Left at stdio-bridge only for now.

## 2. Standalone settings GUI

"Settings menu should stay" — it does, in the pi-chat panel
(`SettingsWindow.qml` + `IntegrationsBridge.qml`), which already speaks *only*
broker protocol and is harness-agnostic in its logic. But it is still surfaced
**inside pi-chat**. A user whose harness is Claude Code / Cursor has no way to
enable/provision/setup integrations without launching pi-chat.

**Decide:** extract the settings section into a standalone quickshell app
(fully decoupling management from pi, matching what we did for confirmations),
or accept pi-chat as the provisioning surface. Kept in pi-chat for now.

## 3. Headless / no-display confirm path

The default confirm command is a quickshell popup — it needs a running Wayland
session. On a **remote executor** (`pi-sessiond` per-user server, no desktop)
or any headless run, the popup cannot render, so the confirm command times out
→ fail-closed **deny** for every effect tool. The old design had "block +
notify" parking for unattended sessions.

**Decide:** the headless confirm channel — a notify + out-of-band approval
(phone, another device), a TTY prompt, or routing confirms to a paired desktop.
Ties into #9. Not built; headless effect tools currently deny.

## 4. Session-grant semantics across reconnects

"Allow for this session" is scoped to one **MCP client connection** in the
gateway. If the harness reconnects (crash, restart, network blip), session
grants are lost and the next effect re-prompts. Finer/again-persisted grants
(the req-8 "allow forever" + args-bound shape) remain deferred as in the POC.

**Decide:** is per-connection acceptable, or key grants to a stable client id?

## 5. Concurrent clients / multiple popups

One gateway `--user` service serves every local harness at once. Two harnesses
hitting effect tools simultaneously ⇒ two confirm popups. No serialization or
per-popup focus stealing handling yet.

**Decide:** serialize confirms, tag popups with the requesting client, or leave
as-is (rare in practice).

## 6. Socket peer-auth (pre-existing residual, now also the gateway socket)

`AF_UNIX connect()` is not Landlock-mediated and ABI-6 IPC scoping covers only
*abstract* sockets, so a same-uid agent that discovers a pathname socket can
`connect()` it. This already applied to the integration sockets (the gateway is
the intended sole client); it now also nominally applies to the **gateway
socket** the agent legitimately uses. Same mitigation as before: FS
non-disclosure + gateway as the sole approval point.

**Decide:** add `SO_PEERCRED`/credential checks on the integration sockets (only
the gateway's uid/pid may connect) and, if desired, restrict who may connect to
the gateway socket. Closes the direct-connect bypass. Deferred as in the POC.

## 7. Agent-proposed enable as a gateway MCP tool

Design §5.6's `propose_integration` (agent proposes, user accepts in the panel)
was a built-in pi tool, out of POC scope. In the generic model it would be an
ordinary **gateway MCP tool** (`propose_integration`) any harness sees, whose
effect is parked to the settings/broker for a user accept. Not built.

## 8. Output screening in the gateway

Design §3F/§8's defence-in-depth (screen integration *output* for known secret
plaintexts before it reaches the harness) now has an obvious home: the gateway,
which sees every `tools/call` result. Not built.

## 9. Remote-executor topology (`pi-chat-remote` / `remote-agent-vm`)

The remote executor runs `pi-sessiond` on a server (no desktop) with the panel
on a client. Where the gateway runs (server, next to the integrations) and where
its confirm popup renders (client desktop) needs wiring — the confirm command
would have to reach across the WebSocket to the client. Overlaps #3. The local
desktop path is complete; the remote split is not addressed.

## 10. Full-VM e2e for the new topology (removed with the old gateway)

`checks/integration-poc-machine` drove the OLD in-`pi-sessiond` gateway (tool
calls over the rpc pipe, approvals auto-answered over the executor WebSocket).
It was removed with that gateway. Its unique coverage — the real TPM2 secret
path, the same-uid Landlock wall (agent can't read an integration's private
state), the cross-user (alice/bob) matrix, and file exchange (clone → agent
edits → PR behind approval) — is **not yet re-authored** for the standalone
topology. The cheap checks (`spaces-integration-gateway-{unit,e2e}`,
`spaces-integration-confirm`, `spaces-integrations-nix-eval`, the broker Go
tests) cover the gateway logic, the confirm contract, the policy lowering, and
the secret encryption; a new VM test should re-establish the *cross-subsystem*
e2e: boot the gateway `--user` service, point pi's extension at it, drive an
effect tool through a headless/auto confirm command, and re-assert the secret /
Landlock / cross-user matrix. Needs the full VM boot to verify (heavy), so it
was not done in the same pass as the extraction.

Also unverified in a running compositor (only headless-contract-tested): the
confirm popup's *visual* correctness (layout, contrast, focus) and that the
sandboxed pi child can actually `connect()` the gateway socket through its
Landlock domain (expected to work — `AF_UNIX connect()` is not Landlock-mediated,
per the POC finding — but confirm in `agent-vm`).
