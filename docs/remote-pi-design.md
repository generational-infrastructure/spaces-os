# Design: remote pi — a TypeScript daemon supervising sandboxed pi subprocesses

**Status:** in implementation (branch `pi-remote-chat`). Live progress + the
remaining-work checklist: [`remote-pi-status.md`](./remote-pi-status.md).

**Goals:**

- **Multiple execution sites, coexisting — this is the core goal.** pi+LLM
  can run in more than one place *at the same time*: on the **desktop itself**
  (exactly as today — sandboxed, local LLM, works offline) **and** on the
  **always-on server**. Each site is an *executor*; the design generalizes to
  **1..N machines**, the desktop and server being the first two. The user
  chooses, per session, which executor runs it. We are *adding* the server as
  an option, **not replacing** local execution.
- **Background continuity.** Server-hosted tasks keep running while the
  desktop sleeps.
- **Many clients, one conversation.** A session is reachable from several
  clients (quickshell now; web UI, phone, PWA later), mirrored live.
- **Sandbox preserved everywhere.** pi's per-session sandbox is intact on
  every executor, including the desktop.

**Scope now:** a **single user** (multi-user deferred; §9).

This document is the design for the agent-side service, plus the alternatives
considered and rejected, so the decision is durable.

---

## 1. Decisions locked in

| Question | Decision | Consequence |
|---|---|---|
| Executors | **1..N self-contained "LLM + PI" units** | Each executor (the diagram's *LLM + PI* box, a.k.a. a *Harness*) bundles its own llama-swap + `pi-sessiond` + sandboxed pi subprocesses and serves one user. Desktop and server each run one; generalizes to more machines. |
| Inference | **Co-located, per executor** | Each executor uses its own GPU (desktop GPU locally, server GPU on the server). Desktop can sleep without affecting server sessions; local sessions work fully offline. |
| The server | **One executor among others** | Home-LAN, always-on; we control hardware + network. |
| Client reach | **LAN-only now, mesh-ready** | Phone works on home WiFi for now. Off-LAN reach is later config (mesh VPN), not a redesign. |
| Executor discovery | **Static config list (NixOS module)** | Each executor = a stable id + WS address handed to the panel; `localhost` is always present, the server is one entry. Liveness = "does the socket answer" (the diagram's *if online*). No discovery protocol; stage 4 adds one entry. |
| Users | **One user per executor ("one user per Harness")** | Multi-user = *more executors*, not a multi-tenant daemon: each user brings their own pi; an LLM may be shared underneath (§9). Single user is the scope now. |
| Auth | **One pre-shared token, no TLS** | The daemon drives a `bash`-capable agent, so `hello` rejects any connection lacking the shared secret — the only gate on "run commands as you." Transport is plain WS for now; the token is app-level auth, orthogonal to TLS. It ships in the same NixOS executor config that lists addresses. Per-device tokens + TLS are later steps. |
| Unattended confirm | **Block + notify** | A turn that needs a human with no client attached *parks*, pushes a notification, resumes when any device answers. Never auto-acts; may stall until acknowledged. |
| Language | **TypeScript daemon** | Drives pi using **pi's own exported types** — protocol/extensions track the npm version, nothing to hand-port (the opencrow Go pain, §10). |
| Execution model | **Sandboxed `pi --mode rpc` subprocess per session** | The daemon spawns each session as a `systemd-run`-sandboxed subprocess and bridges its stdio. Per-session sandbox + crash isolation. Cost: the daemon consumes pi's RPC line protocol (cheap in TS w/ pi's types). |
| Transport | **Uniform WebSocket, every executor** | One client code path; "local" is just an executor on `localhost`. Same wire whether the executor is desktop or server, so adding the server is config, not new transport code. |
| Session migration | **Deferred; resume-from-committed when it lands** | Not in the first draft. When added, migrating a session = a cold attach on the target (spawn `pi --continue`, replay committed jsonl); the in-flight turn is dropped. Same protocol, but the live turn / `seq` / buffer are *not* portable — so nothing in the first draft must make them so. |
| Connectivity | **n:m clients × sessions** | The one user has many clients and many sessions; any client may attach any session; any session may be mirrored by many clients. |

---

## 2. Why this shape

Established over prior exploration (recorded so it isn't relitigated):

- **A resident server-side process is unavoidable.** pi v0.78.0 is
  point-to-point and stdio-only (`--mode rpc` = JSON-lines over
  stdin/stdout, *"no socket/port/network,"* *"no detach/background/
  reconnect"*). To keep a session alive past a client (background tasks)
  and share it across clients (a pipe has one reader), *something* must stay
  resident, own the session, and fan its output out. That is `pi-sessiond`.
- **TypeScript, not Go.** What killed opencrow was a *Go* bridge
  hand-reimplementing pi's RPC surface and chasing its protocol quirks (§10).
  A TS daemon uses pi's **own** exported command/event types and loads pi's
  **own** extensions (`pi -e …`) — so a pi upgrade is an `npm` bump, not a
  porting project. opencrow's transport flattening is gone too: we forward
  the full event stream.
- **Subprocess execution, not SDK-embedded.** We deliberately do *not* use
  the SDK's in-process `createAgentSession`. Each session is a
  `systemd-run`-sandboxed `pi --mode rpc` subprocess (the same sandbox
  bouquet `PiSession._buildCommand` builds today), so per-session filesystem
  narrowing, the `trusted` flag, and crash isolation are preserved on every
  executor — including the desktop, where pi touches your real home dir and
  the isolation matters most. The price is that the daemon parses pi's RPC
  line protocol; in TS against pi's types that is mechanical, and the daemon
  only peeks at a handful of event types for routing (§5.2).

---

## 3. Domain model

```
Executor ("LLM + PI" / Harness)  one per machine that runs the agent:
        = llama-swap + pi-sessiond + sandboxed pi subprocesses, one user
Machine  may host an executor, a chat client, or both:
        server → executor only · laptop → executor + client · phone → client only
Client ──*:*── Session     Subscription (attach) — THE n:m edge
Client ──*:*── Executor    a chat client may attach to several executors at once
                           (its own local one and/or remote ones)
Session ──1:1── pi subprocess  live, sandboxed `pi --mode rpc`
        └──1:1── session.jsonl  on-disk persistence (lives on the executor)
Session ──*:1── Executor   the executor that hosts it
Connection = one live transport instance of a Client to one Executor
```

An **executor** is the diagram's *LLM + PI* box (a *Harness*): a self-contained
agent runtime for one user. A **chat client** (quickshell panel, web UI, PWA)
is thin and **multi-homing** — it can attach to its own machine's executor
*and* to remote executors simultaneously, presenting one merged session list.
Everything belongs to the single user, so there's no user partition to enforce.

---

## 4. Topology

Mirrors the target architecture: every machine that runs the agent hosts a
self-contained **executor** ("LLM + PI"); chat clients attach to whichever
executors they can reach.

```
  ┌─ Server ─────────────┐  ┌─ Laptop 1 ───────────┐  ┌─ Laptop 2 ───────────┐  ┌─ Phone ──────┐
  │  LLM + PI (executor) │  │  LLM + PI (executor) │  │  LLM + PI (executor) │  │  Chat Client │
  │                      │  │  Chat Client         │  │  Chat Client         │  └──────────────┘
  └──────────────────────┘  └──────────────────────┘  └──────────────────────┘
```

Connectivity (which chat client attaches to which executor):

- **Laptop 1** client → its **own** executor (local) **and** → the **Server**.
- **Laptop 2** client → its **own** executor (local) **and** → the **Server**.
- **Phone** client → the **Server** executor over a **PWA**, **and** → the
  **Laptop 2** executor **if online** on the same network.

So: laptops are *both* executor and client; the server is executor-only; the
phone is client-only. Each client merges the session lists of every executor
it's attached to. **No gateway** — each executor exposes its own token-auth
WebSocket and clients pick which executor(s) to talk to.

### 4.1 An executor = "LLM + PI"

llama-swap (its own GPU/models) + `pi-sessiond` (token-auth WS listener +
session registry + hub + side-channel router + notifier) + the sandboxed
`pi --mode rpc` subprocesses. Runs as the user's uid inside a NixOS-container
sandbox. One user per executor ("one user per Harness"). Same binary
everywhere; an executor is just a `pi-sessiond` at some address.

### 4.2 LLM per executor

Each executor runs its **own** llama-swap next to its pi subprocesses (desktop
GPU locally, server GPU on the server) — there is **no** single shared LLM in
this topology. Per-session model selection is unchanged (llama-swap hot-swaps;
OpenRouter is per-session too). *Multi-user note:* if several users share one
machine, the llama-swap *may* be shared while each user still runs their own
`pi-sessiond` — see §9.

---

## 5. `pi-sessiond` internals

Five layers:

1. **Transport** — accepts a WS connection, checks the token on `hello`,
   assigns a `connectionId`.
2. **Subscription hub** — the `connection × session` attach graph. Fans
   session events *out* to attached connections; serializes inbound commands
   *in* to the one subprocess's stdin.
3. **Session registry** — `sessionId → subprocess handle`; lifecycle,
   persistence, the per-session event sequence + turn buffer.
4. **Side-channel router** — `extension_ui_request` / open-url / notify
   routing + the block-and-notify policy (§6).
5. **Notifier** — push channel for parked requests / background completion.

### 5.1 Session lifecycle

States: `cold` (on disk only, no subprocess) · `live-idle` · `live-busy`
(turn streaming) · `parked` (blocked on a human, §6).

- `create_session` → spawn a sandboxed `pi --mode rpc` subprocess → **live-idle**.
- attach to `cold` → spawn with `--continue` (replays committed jsonl) →
  **live-idle**; send snapshot.
- prompt → **live-busy**; `agent_end` → **live-idle**.
- `extension_ui_request`, ≥1 client attached → broadcast, stay live-busy.
- `extension_ui_request`, 0 clients → **parked** + notify.
- all clients detach, live-idle, no background/scheduled work → idle-GC after
  a timeout → stop the subprocess → **cold** (reload on next attach).
- **Never GC a live-busy or parked session** — the daemon (not the client)
  owns the subprocess, so background tasks survive a sleeping desktop.
- **Crash isolation:** a subprocess that exits non-zero takes down only its
  own session; the daemon records the exit, surfaces it to attached clients,
  and can respawn with `--continue` (mirrors today's
  `PiSession._processComponent.onExited`, server-side).

### 5.2 Daemon parses *shallowly*; the client keeps the rich logic

The daemon does **not** reinterpret pi's message-delta stream. It reads
LF-delimited JSON lines (with a **protocol-compliant** reader — Node's
`readline` is *not* compliant, it also splits on U+2028/U+2029), stamps each
event with a per-session monotonic `seq`, and **forwards it verbatim** inside
an envelope. It peeks at `event.type` only for the few control cases it must
act on: `agent_end` (turn boundary), `extension_ui_request` (side-channel
routing), `response` (correlation + fan-out). All bubble assembly, streaming
text, thinking, tps, etc. stays in the client's existing `PiSession` state
machine — no duplication.

### 5.3 Event sequencing & reconnect

The ring buffer of recent events (≥ the current turn) covers the gap between
pi's committed jsonl and the live streaming cursor.

- **Cold attach** (no seq): send a `snapshot` (history from `get_messages`)
  + current seq, then live events from `seq+1`.
- **Warm reattach** (client sends `lastSeq`): within the buffer window →
  replay `lastSeq+1…`; else snapshot + tail.

This is what lets a phone wake, or a desktop return from sleep, and catch up
to a turn that streamed while it was gone — which raw `--continue` can't do
(it only replays *committed* messages, losing the in-flight turn).

### 5.4 Command fan-in & concurrency

Many clients → one subprocess stdin. The hub serializes:

- prompt → forward the client's `{type:"prompt", …, streamingBehavior}`
  verbatim. The client tags the command (e.g. `streamingBehavior:"steer"`),
  pi owns the queue and decides fresh-turn vs steer from its own busy
  state. The daemon does **no** verb mapping — there is no separate
  `steer` / `follow_up` command to pick between.
- abort / set_model / set_thinking → forward; last-writer-wins.
- **`response` events fan out to all attached clients.** The originator
  resolves its correlated request by `id`; mirrored clients fall through to
  by-command state handling and pick up e.g. a model change made on another
  device — exactly the existing `PiSession._handleResponse` structure, so
  mirroring needs no new client logic.

---

## 6. Side channels & the block-and-notify policy

`extension_ui_request {id, method}` belongs to a session → routes only to
clients attached to **that** session.

| method | routing |
|---|---|
| `confirm` / `input` / `select` / `editor` | broadcast to attached clients; **first answer wins**; tell the others to collapse via `sidechannel_resolved {id, by}`. |
| `open_url` | route to the **active** client (the connection whose prompt drove the turn); unknown → most-recently-active. |
| `notify` | broadcast to attached; none → push via notifier. |

**No client attached:** the daemon **parks** the request (holds it, marks the
session `parked`) and fires the notifier. The pi subprocess's agent loop is
genuinely blocked awaiting the response — fine, it just sits resident. On the
next attach, parked requests are replayed in the snapshot; the user answers;
the daemon writes `extension_ui_response` to the subprocess; the turn resumes.
Accepted trade-off: a background task can stall indefinitely if you never
acknowledge it — the safe failure mode.

(Future refinement, out of scope: a per-session *allowlist* so pre-approved
actions don't park. The `trusted` flag is the seam to build on.)

---

## 7. Transports as adapters (and where the notifier comes from)

The hub emits to an abstract **transport adapter**:

- **Native WebSocket adapter** — carries pi's full event stream verbatim.
  quickshell / web UI / PWA attach here and keep streaming, thinking, tool
  bubbles, inline confirms, model switching, tps.

---

## 8. State & isolation

- **State dir** (server-side): `~/.local/state/spaces/pi/sessions/<id>/session.jsonl`
  (pi) + a daemon-owned **session index** (names, executor, workspace, model
  pref, lastSeq checkpoint, timestamps) — sqlite or json. The daemon is now
  authoritative for the index; `PiChatBackend`'s client-side `sessions.json`
  becomes a *view* of `list_sessions`.
- **skill-config moves server-side.** Today it's a desktop daemon with a
  socket bound into the local sandbox; with pi remote, the config *store* and
  skill execution environment live next to `pi-sessiond`, and "request-input"
  round-trips to a client as a `sidechannel` input request. Migration item.
- **Per-session sandbox preserved everywhere.** Because every session is a
  `systemd-run`-sandboxed subprocess, the `ProtectHome=tmpfs` / narrowed
  `BindPaths` / `trusted`-flag model from `PiSession._buildCommand` carries
  over unchanged — including on the desktop executor. (SDK-embedded execution
  would have lost this; see §10.)

---

## 9. Multi-user (deferred): more executors, not a multi-tenant daemon

Per the architecture's own decision — *"one user per Harness; if users want to
share LLMs, each brings their own Pi"* — multi-user is **not** a multi-tenant
`pi-sessiond`. It is simply **more single-user executors**:

- Each user runs their **own** `pi-sessiond` (their own *Pi*), as their own
  uid, with their own token and state dir — full OS-level isolation, for free.
- The **LLM may be shared**: several users' pi-sessionds can point at one
  llama-swap on a shared machine (it already hot-swaps per request). That
  decomposes the *LLM + PI* box into a shared LLM + per-user Pi.
- Clients are unaffected: a chat client just attaches to the executor(s) for
  *its* user. An optional front router could later add a single endpoint +
  SSO, but it isn't required — clients can address per-user executors directly.

Do **not** build this now; it's recorded so nothing in the single-user design
blocks it (and nothing does — the daemon is already single-user-scoped).

---

## 10. Alternatives considered & rejected

- **SSH-pipe the RPC** (`ssh server pi --mode rpc`). Dies with the
  connection (no background), each client its own pi (no sharing), local
  side-channel sockets break. Worth one afternoon as a "protocol survives a
  hop" smoke test, then discard.
- **Expose pi's socket directly** (`socat TCP-LISTEN EXEC:"pi --mode rpc"`).
  One client for the connection's lifetime. A pipe has one reader — fan-out,
  reconnect, background-survival, park-and-notify all need a resident process.
  Legitimate only if you drop all four goals.
- **SDK-embedded execution (in-process).** Cleanest protocol story, but runs
  all sessions in one process/uid → no per-session sandbox, no crash
  isolation. Rejected for sandboxed subprocesses (§1, §2); the sandbox matters
  most on the desktop where pi touches your real home dir.
- **SDK-only, embedded in the client.** No daemon, but the agent dies with
  the client and can't be shared. Same trade as socat.
- **Bring back opencrow (Go, RPC-bridge, chat-only).** Post-mortem: it
  hand-marshalled pi's whole RPC surface in Go (`pi_rpc.go`: a wall of
  `rpcType*` constants, camelCase tags, fragile `agent_end`/retry sequencing)
  and **flattened to final text** (`w.reply = last.text`). Its pains map onto
  (a) Go-over-RPC — *structural*, no Go SDK — and (b) chat-only flattening — a
  regression for the rich panel. **Verdict:** don't re-add it as the core; a
  TS daemon using pi's own types is the cure for (a). **Keep its best idea** —
  chat as a *transport adapter* (§7), plus `heartbeat` / `reminders` /
  `trigger.pipe` as background-task triggers.

---

## 11. Client (quickshell) changes

`PiSession.qml`'s event state machine is transport-agnostic and stays. What
changes:

- Replace the local `Process` / `systemd-run --pipe` transport with a
  **WebSocket** to a `pi-sessiond` (this spawn+parse logic effectively *moves
  into* the daemon); `hello` carries the pre-shared token.
- `spawn()`/`stop()` → `attach`/`detach` envelopes (the daemon decides
  whether a subprocess needs (re)spawning).
- `_send` wraps `{kind:"command", sessionId, payload}`; `_onLine` unwraps
  `{kind:"event", sessionId, seq, payload}`; handle `snapshot`, `attached`,
  `sidechannel`.
- The local side-channel UNIX sockets (`skill-config`, `open-url`) go away on
  the client; those arrive inline as `sidechannel` envelopes and the panel
  performs the desktop-side *effect* locally (open the browser on the desktop).
- Multi-session already exists (the `Repeater` of `PiSession`); each now maps
  to an `attach`. The session list is a merged view of `list_sessions` across
  the executors the panel knows (the `localhost` daemon and the server).
  `create_session` gains an `executor` field; per-session model selection is
  unchanged and scoped to that executor's available models.

---

## 12. Protocol envelope (daemon ⇄ client)

The inner `payload` is byte-for-byte pi's existing command/event protocol;
the envelope only adds addressing + the control verbs the pipe model lacked.

```jsonc
// client → server
{ "v":1, "kind":"hello", "token":"<shared-token>", "client":{...} }
{ "v":1, "kind":"list_sessions" }
{ "v":1, "kind":"create_session", "executor":"server|local", "name?":..., "workspace?":..., "model?":... }
{ "v":1, "kind":"attach", "sessionId":"…", "lastSeq?":1234 }
{ "v":1, "kind":"detach", "sessionId":"…" }
{ "v":1, "kind":"command", "sessionId":"…", "payload":{ /* pi command */ } }
{ "v":1, "kind":"sidechannel_response", "sessionId":"…", "id":"…", ... }

// server → client
{ "v":1, "kind":"welcome", "connectionId":"…", "caps":{...} }
{ "v":1, "kind":"sessions", "sessions":[ {id,name,executor,state,updated,…} ] }
{ "v":1, "kind":"attached", "sessionId":"…", "seq":1234 }
{ "v":1, "kind":"snapshot", "sessionId":"…", "messages":[...], "seq":1234, "parked":[...] }
{ "v":1, "kind":"event", "sessionId":"…", "seq":1235, "payload":{ /* pi event */ } }
{ "v":1, "kind":"sidechannel", "sessionId":"…", "id":"…", "method":"confirm|input|open_url|notify", ... }
{ "v":1, "kind":"sidechannel_resolved", "sessionId":"…", "id":"…", "by":"<connectionId>" }
{ "v":1, "kind":"error", ... }
```

---

## 13. Open questions for the next pass

- **Session ↔ workspace mapping.** *First draft:* one auto-created scratch
  dir per session (`~/.local/share/spaces/workspaces/<id>` — today's
  `PiChatBackend` behaviour), bound into the sandbox and owned by the daemon.
  Shared / user-chosen workspaces, and a portable (per-executor-resolved)
  workspace identity, are deferred — the latter is the real gate on migration.
- **Token provisioning & rotation.** *Decided:* one pre-shared token, shipped
  via the same NixOS executor config that lists addresses; `hello` checks it,
  no TLS. *Open:* rotation, and per-device tokens (revoke one device) as the
  bridge toward §9.
- **Idle-GC timeout & subprocess ceiling** per `pi-sessiond`.
- **Non-image attachments under base64-only.** pi's prompt `images` array is
  typed for images; inlining a non-image blob needs a content channel or is
  deferred to the future `POST /files` handoff (the current "drop the path,
  let pi `Read` it" behaviour cannot work remotely).
- **Voice-to-text** (`voxtype`) stays desktop-local (types into the focused
  window) — confirm we leave it alone.

---

## 14. Staged migration

Each stage is independently useful; lock behaviour with cheap `checks/`
tests (`checks/pi-rpc-streaming/` is the template).

1. **`pi-sessiond` as the desktop's local executor.** Move the
   spawn-sandboxed-pi + parse-RPC logic out of `PiSession.qml` into the
   daemon; the panel connects to it over WS on `localhost` + token. This
   alone reproduces today's local, sandboxed, offline behaviour on the new
   uniform transport — no server involved yet.
2. **Session registry + n:m.** Multi-session attach graph, fan-out/fan-in,
   mirror across the user's clients.
3. **Sequencing + reconnect** (snapshot/resume, turn buffer).
4. **The server executor.** Run the *same* `pi-sessiond` binary on the
   always-on box; the panel multi-homes (local + server) and merges
   `list_sessions`. Background continuity (tasks survive a sleeping desktop)
   arrives here.
5. **Side-channel routing + block-and-notify** — makes background tasks
   *useful*, not just *running*.
6. **Chat adapter** (phone reach + notifier) and **web UI / PWA** — new
   clients of the same protocol, no daemon changes.
7. **(Later) mesh VPN** for off-LAN reach, and **multi-user** (§9) — both
   config/topology, not protocol changes.
```
