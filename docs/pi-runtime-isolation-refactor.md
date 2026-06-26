# Design: pi runtime isolation (sandboxed pi-sessiond)

**Status update (confinement superseded).** The supervisor/RPC-pipe inversion
below is unchanged and shipped. The per-session confinement, however, is **no
longer a `PrivateUsers=managed` user namespace** — both executors now confine
each pi child with a self-applied **Landlock** domain (see
[landlock-sandbox-design.md](./landlock-sandbox-design.md)). The `managed`-userns
path, `nsresourced`, and the `pi-sessiond-sandbox-wall` check referenced below
have been deleted (`pi-sessiond-sandbox` was repurposed to unit-test the new
Landlock policy/argv emitter); read the managed-userns specifics as
historical. The threat model and the supervisor architecture still apply.

**Goal:** invert `pi-sessiond` so the **entire pi runtime** — the model
loop, every tool, the file tools, and any extension — runs inside a
per-session sandbox (a `--user` `PrivateUsers=managed` service), driven
by a thin trusted **supervisor** over pi's headless RPC protocol. The
supervisor (uid 1000) runs no model-controlled code.

This refactor is a **prerequisite** for
[agent integrations](./agent-integrations-design.md): that design's
central invariant — *no code the model can steer ever runs bare as
uid 1000* — is unenforceable while pi is embedded in-process at uid 1000.
This document is the runtime change that makes the invariant true by
construction.

---

## 1. Why this must come before integrations

The integrations design (§1) rests on one invariant: the secret
boundary is **uid + namespace**, and the agent's whole execution domain
must sit in a `managed` user namespace that is a *sibling* of the
integration namespaces — never bare uid 1000, because **the uid that
creates a namespace owns everything inside it** (`user_namespaces(7)`).
If any model-steerable code runs as uid 1000, it owns every integration
namespace and can `ptrace`/read every integration's secrets — req 1
(the agent can never read secrets) is void.

Today `pi-sessiond` violates this directly. It **embeds pi in-process**
(`createAgentSession`, `main.ts`) at uid 1000 and only swaps the single
`bash` tool for a `systemd-run` sandbox. Everything else the model
drives runs in the daemon:

- **Extensions are arbitrary in-process code.** `extensions/loader.ts`
  loads `.ts`/`.js` via jiti with full SDK access. Discovery
  (`resource-loader.ts`) scans `agentDir/extensions/` and
  `cwd/.pi/extensions/` (where `cwd = workdirOf(id)`, the per-session
  workspace), enabled-by-default, reloaded on **every session create and
  resume**.
- **The file tools run in-process.** `createEditToolDefinition(workdir)`
  / `createReadToolDefinition(workdir)` use the SDK's default in-process
  IO at uid 1000 — only `bash` got the sandbox treatment.

So the model can write `workdir/.pi/extensions/x.ts` with the in-process
`edit` tool; on the next resume the loader executes it in the daemon at
uid 1000 → it escapes the `bash` sandbox, owns every integration
namespace, reads all secrets, sees all sessions, and can subvert the
gateway (the approval enforcement point lives in the same process).

This is not one bug to patch. It is a **class** of holes — extensions,
in-process file tools, eval-shaped tools, anything pi loads — and a
blocklist will always miss one. The fix is structural: stop trying to
keep dangerous code *out* of the trusted process; instead put the
**whole runtime** in the sandbox and keep the trusted process tiny.

---

## 2. The inversion

Today the trust assignment is backwards: the model-bearing process is
"trusted" and spawns a small sandbox. Flip it.

```
        ┌──────────────────────────── uid 1000 (trusted) ─────────────────┐
        │  supervisor (was pi-sessiond)                                    │
clients │  • WebSocket transport, auth, session list/lifecycle            │
◀──WS──▶ │  • gateway: manifest + approval enforcement, output screening   │
        │  • integration sockets (MCP) + broker/panel side-channels        │
        └───▲───────────────────────────────────────────────────────▲─────┘
            │ rpc (stdin/stdout JSON lines, one per session)          │ MCP
            │                                                         │ (unix sockets)
   ┌────────┴─────────┐  ┌──────────────────┐            ┌───────────┴──────────┐
   │ pi session A     │  │ pi session B     │   …        │ integration units    │
   │ --user managed   │  │ --user managed   │            │ --user managed       │
   │ userns (uid≠1000)│  │ userns (uid≠1000)│            │ userns (uid≠1000)    │
   │ loop+tools+bash  │  │ loop+tools+bash  │            │ (siblings, walled)   │
   │ +extensions      │  │ +extensions      │            └──────────────────────┘
   └──────────────────┘  └──────────────────┘
   (siblings, mutually walled; cannot reach integration units)
```

- **Supervisor (uid 1000, trusted):** the WebSocket transport + session
  lifecycle that `pi-sessiond` already owns, **plus** the integration
  **gateway** (the §5.3 policy enforcement point: manifest, per-call
  approvals, output screening, the integration MCP sockets, broker/panel
  side-channels). It runs **no model-controlled code** and loads **no**
  extensions.
- **Per-session pi runtime (sandbox):** the entire `AgentSession` — model
  loop, tool dispatch, `bash`, the file tools, **and** extensions — runs
  as a `--user` `PrivateUsers=managed` service (distinct host uid via
  `systemd-nsresourced`, the `sandbox.ts` hardening set), one per chat,
  in pi's **rpc-mode** (`modes/rpc/rpc-mode.ts`: headless JSON
  stdin/stdout — *"for embedding the agent in other applications"*).
  Driven entirely over its stdin/stdout pipe by the supervisor.

The sandbox's **only** outward channel is that one typed RPC pipe.

---

## 3. The control protocol (the entire trusted surface)

The supervisor drives each sandboxed pi over JSON-line RPC — pi already
defines it (`modes/rpc/rpc-types.ts`):

- **commands in:** `prompt`, `steer`, `abort`, `set_model`,
  `set_thinking_level`, `compact`, … — exactly the inbound `command`
  payloads the WebSocket handler routes today.
- **events out:** the `AgentSessionEvent` stream — forwarded to attached
  clients in the existing seq-stamped envelopes.
- **side-channel out / in:** extension-UI / approval requests surface
  over the protocol (`RpcExtensionUIRequest`/`Response`); the supervisor
  routes them to the panel (block + notify) and replies. This is where
  the current in-process `uiContext` binding goes.
- **integration tool calls:** the model's integration tools are **thin
  stubs** inside the sandbox that forward the call over this channel; the
  supervisor's gateway checks the manifest/approval, executes against the
  integration MCP socket, screens output, and returns the result. The
  sandbox **never holds an integration socket**.

Everything the model can do that touches the world crosses this one
pipe, and the supervisor validates it (the same discipline it already
applies to client WebSocket messages). The trusted surface shrinks from
"every tool + the extension loader + in-process file IO" to "one typed
RPC parser." That is the whole point: a boundary you can audit.

---

## 4. What this buys

- **The §1 invariant becomes true by construction.** The model may load
  any extension, run any code, write any file — all inside its `managed`
  userns (host uid ≠ 1000, sibling to integrations). It cannot reach an
  integration socket, cannot `ptrace`/read integration secrets, cannot
  touch other sessions (per-session sandbox), cannot subvert the gateway
  (it lives across the boundary). No enumeration, no blocklist.
- **"The agent never holds an integration socket" (§3D) is enforced by
  namespace,** not convention.
- **Approval enforcement is structural.** A self-loaded extension can no
  longer auto-approve effect calls — the enforcement point is in the
  supervisor, unreachable from the sandbox.
- **`bash` stops being special.** No per-command `systemd-run` wrapper —
  `bash` runs inside the already-sandboxed runtime. `sandbox.ts`
  repurposes from "wrap each bash command" to "define the per-session
  pi-runtime unit."
- **Cross-session isolation** comes free from per-session sandboxes
  (sibling `managed` userns), where today all sessions share one daemon
  process.

---

## 5. What stays trusted, and why

- **The gateway / approval enforcement** must be in the supervisor. If it
  lived in the sandbox a self-loaded extension could bypass it. Across
  the boundary the model can only *request*; the supervisor decides and
  executes. (Proposing an integration to enable — agent-integrations
  §5.6 — is just another request over the pipe.)
- **The broker/panel side-channels** stay supervisor-side; secrets never
  enter a session sandbox (they go to integration units via
  `LoadCredentialEncrypted=`, agent-integrations §5.2).
- **Session persistence ownership.** `session.jsonl` / `workdir` are
  owned by the delegated sandbox uid; the supervisor (uid 1000, owner of
  the namespace) can still read them for the session list. `StateDirectory`
  is re-chowned to the delegated uid at each start (delegated uids are
  ephemeral — agent-integrations §7).

---

## 6. Things to get right (bounded, not blockers)

1. **The RPC pipe is the trusted surface** — keep it narrow and typed;
   validate everything pi emits. Far smaller than today's surface.
2. **LLM key / egress.** The loop runs in the sandbox, so either (a) the
   sandbox gets egress to the provider and holds the LLM key (agent-grade,
   acceptable), or (b) the supervisor **proxies** LLM calls so the key
   stays trusted and the sandbox needs no general network. Prefer (b) if
   the sandbox should be networkless except through mediated channels.
3. **File exchange.** The per-pair shared dir is idmapped into both the
   session sandbox and the integration unit (distinct host uids; the
   two `managed` ranges share no uid — agent-integrations §8).
4. **Lifecycle/cost.** One `managed`-userns unit per live session;
   `MAX_LIVE` / idle-GC become start/stop of units. `nsresourced`
   delegates a uid range per unit.
5. **rpc-mode tool surface.** Integration-tool stubs must be injected
   into the sandboxed pi (as customTools/an extension loaded from the
   read-only runtime image, never from a session-writable path) and
   forward over the RPC channel; built-in `bash`/file tools run locally
   in the sandbox.

---

## 7. What it removes

- The per-command `systemd-run` bash wrapper (`sandbox.ts` becomes a unit
  definition).
- The "enumerate and block every code-load surface" burden (extensions,
  in-process file tools, …).
- The extension-self-load escape, as a special case — it is now contained
  by the same boundary as everything else.

---

## 8. Open questions

- **rpc-mode coverage.** Does pi's rpc-mode expose every command the
  current WebSocket handler needs (thinking level, model cycle, fork,
  compaction)? `rpc-types.ts` lists most; verify the full set, or extend
  rpc-mode. Architecture-irrelevant but determines refactor size.
- **Tool-call mediation shape.** Whether integration tools are best
  modelled as customTool stubs forwarding over RPC, or as a driver-owned
  tool class in rpc-mode. Pick the one that keeps enforcement
  supervisor-side with the least glue.
- **LLM-call proxying** (item 6.2) — proxy vs. in-sandbox key.
- **Embedding vs. spawning.** Today the supervisor embeds pi via the SDK;
  the refactor spawns pi (binary) in rpc-mode per session. Confirm the
  SDK/binary packaging path under Nix.

---

## 9. Migration plan

The refactor lands **before** any integration sandbox/broker work, since
integrations assume it.

1. **Supervisor skeleton.** Keep the existing WebSocket transport +
   session list; replace in-process `createAgentSession` with: spawn a pi
   rpc-mode child per session, pipe its stdio, translate WebSocket
   `command` ↔ RPC, forward events. No sandbox yet — prove the drive
   path (cheap headless check against a stub pi).
2. **Sandbox the child.** Wrap the rpc child in a `--user`
   `PrivateUsers=managed` unit with the `sandbox.ts` hardening set + the
   one-time platform prereqs (`nsresourced`,
   `kernel.unprivileged_userns_clone=1`). Verify `bash`/file tools/an
   extension all run, and that the child runs as a distinct host uid.
3. **Move the gateway to the supervisor.** Integration tools as RPC-forwarded
   stubs; enforcement (manifest/approval/output-screen) supervisor-side;
   the integration MCP sockets reachable only from the supervisor.
4. **Verify the wall.** A check asserting the session sandbox cannot
   `ptrace`/read an integration unit (sibling `managed` userns), while the
   supervisor (uid 1000) can mediate.

Only then does the agent-integrations §9 POC proceed on top.

### Checks

- Cheap headless: supervisor drives a stub pi rpc child; commands ↔
  events round-trip; side-channel/approval request surfaces and resolves.
- VM (with `nsresourced`): session child runs as a distinct delegated host
  uid; a planted/loaded extension inside the child cannot reach an
  integration unit or another session; supervisor can.
