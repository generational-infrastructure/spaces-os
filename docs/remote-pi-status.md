# Remote pi — implementation status & continuation plan

Living execution tracker for the remote-pi build. Rationale and the staged
plan live in [`remote-pi-design.md`](./remote-pi-design.md); "stage N" below
refers to its §14. Update this file as work lands.

All work is on branch **`pi-remote-chat`** (not pushed). Checks run with
`nix build .#checks.x86_64-linux.<name>`.

---
## Local-spawn cutover — complete

The panel's legacy local execution path (`PiSession` spawning `pi --mode rpc`
in a per-session `systemd-run --user` unit) is **deleted**. Every chat session
now lives on a pi-sessiond executor; the desktop default is the per-user
loopback daemon (`services.pi-sessiond-local`, enabled by
`services.pi-chat.localExecutor.enable = true`, which is now the default).

Parity ports that made the deletion possible:

- **Skill plumbing** — the daemon stages skills (settings.json) and the
  bash-confirm allow-list (`SPACES_SESSIOND_BASH_CONFIRM`); each per-bash
  sandbox gets the skill env (`SPACES_SESSIOND_BASH_ENV`: skill-config /
  open-url sockets, state dir, notifications file) and binds
  (`SPACES_SESSIOND_BASH_BINDS`: sockets, skills-defs, skill-config store,
  notifications) plus `SPACES_SESSION_ID` and the daemon's PATH via
  `--setenv`. `services.pi-chat.sandboxBinds` keeps its module contract and
  forwards into `services.pi-sessiond-local.bashBinds`.
- **Per-session memory toggle** — new `set_memory` command writes/removes the
  `memory-off` marker in the daemon-side session dir; the memory extension
  resolves it via `ctx.sessionManager.getSessionDir()` (env-based resolution
  removed — one daemon process hosts many sessions).
- **Image attach** — the panel still encodes panel-side; the daemon forwards
  `prompt.images` to the SDK (and `providerModel` now declares
  `input: ["text","image"]` so pi-ai doesn't strip attachments).
- **Request correlation** — commands carry an `id` the daemon echoes on the
  matching response, so `setModelAndWait`/`_request` work over WS;
  `resolveModel` accepts the panel's `provider/id` form.
- **restart() over WS** — delete-old + create-new (create carries
  `model=modelPref`); pi's in-place `new_session` is no longer used by the
  panel.
- **OpenRouter** — `services.pi-sessiond-local.openrouter.enable` LoadCredentials
  the staged key into the daemon.
- **ProtectHome=tmpfs fix** — it empties `/run/user` too; the daemon binds back
  `%t/systemd` + `%t/bus` or `systemd-run --user` (the bash sandbox spawner)
  cannot reach the user manager.

Checks: `pi-session-{quick-launch,quick-launch-model-directive,idle-reap,
attach-image,restart-preserves-model}` migrated to executor harnesses (real
daemon or mock); `pi-session-sandbox-{env,binds}` deleted (argv contract lives
in `pi-sessiond-sandbox` bun tests); nix-eval checks repointed at
`SPACES_SESSIOND_BASH_BINDS`; `test-machine` asserts NO `pi-chat-<sid>.service`
units exist (cutover regression guard).

---
## Architecture revision — SDK-embedded execution (complete)

**Decision reversed: the daemon embeds pi via its SDK instead of spawning
`pi --mode rpc` subprocesses.** The original "sandboxed subprocess per session"
choice is superseded; the design doc now reflects SDK-embedded throughout (§1
table, §2, §5, §8, §10). Why: the subprocess sandbox was the *only* technical
basis for rejecting the SDK and it's addressable; the subprocess daemon as built
never imported pi's types (untyped NDJSON parsing — the fragile half of a Go
bridge with none of the typed-integration benefit); SDK-embedded is the leaner
architecture the project always described, and it's fewer moving parts.

- **Feasibility: confirmed.** The `pi` package ships the SDK at
  `${pi}/lib/node_modules/@mariozechner/pi-coding-agent` (`dist/core/sdk.js` →
  `createAgentSession` / `createAgentSessionRuntime` / `SessionManager` /
  `defineTool` / `ModelRegistry` / `AuthStorage`). Real npm scope is
  `@mariozechner` (public docs say `@earendil-works`). Bun imports it from that
  store path — no offline npm fetch.
- **Executor is a proper Nix package** (requirement): `pi-sessiond` resolves the
  SDK from the pinned `pi` store path and is **parameterized by `pi`**, so
  `services.pi-chat.piPackage` pins both the desktop's local Process path and
  the executor's embedded SDK from one source — no version skew. Supersedes the
  `bun main.ts` zero-dep shim.
- **Sandbox** (§8): pi's built-in `bash` is replaced by a tool whose operations
  wrap each command in the `systemd-run` confinement bouquet `sandbox.ts` builds
  (`buildBashSandboxArgv`); read/edit/write run in-process. Trade: per-session
  crash isolation is weaker (accepted, single-user). Hardening the daemon's own
  unit (ProtectHome etc.) is a follow-up — left out for now so it can't interfere
  with the daemon spawning systemd-run.
- **Scope is daemon-internal.** The §12 protocol and both clients (quickshell
  panel + PWA) and their checks (`pi-session-ws`, `pi-web-*`, `pi-chat-*`) are
  unaffected — the daemon forwards the *same* pi event shapes, now from
  `session.subscribe` instead of parsed rpc stdout. The daemon-level checks
  (`pi-remote-session`, `pi-sessiond-{sandbox,lifecycle,sidechannel}`) are
  re-ported from fake-pi-subprocess to real-pi-via-SDK + a mock model.

Migration tasks — **done**:
- [x] Confirm the SDK is importable in the Bun/Nix build.
- [x] Update the design doc + this tracker to SDK-embedded.
- [x] Research the SDK API (session create w/ local provider, events, prompt,
  confirm via `uiContext`/`bindExtensions`, custom bash tool, `SessionManager`).
- [x] Rewrite `pi-sessiond` core (events→§12; command→`session.*` incl.
  get_state / get_messages / get_available_models; confirm via the SDK
  `uiContext`; `sandbox.ts` → the per-command bash wrapper).
- [x] Package the executor (SDK from the pinned pi, parameterized by `pi`);
  module pins it to `piPackage`, drops `PI_BIN`.
- [x] Load `bash-confirm` per session (`SPACES_SESSIOND_PI_EXTENSIONS`) so the
  confirm side-channel works.
- [x] Re-port the daemon checks and run all affected GREEN.

Verified GREEN (formatted sources): `pi-sessiond-sandbox`,
`pi-sessiond-sidechannel` (first-answer-wins + park + notify),
`pi-sessiond-lifecycle` (idle-GC + ceiling), `pi-remote-session` (drive /
jsonl-persist / 2-client mirror / list_sessions / daemon-restart cold-resume /
get_state), `pi-web-e2e` (connect / streamed reply / confirm+Allow), and — the
real quickshell panel against the migrated daemon — `pi-chat-remote` (panel →
remote executor) + `pi-chat-local-executor` (panel → loopback executor; since
removed as redundant — `test-machine` boots the shipping self-hosted topology
and `pi-chat-remote` covers panel → system `pi-sessiond`), plus
the unaffected `pi-web-serve` / `pi-web-reducer` / `pi-session-ws`.

Running the panel↔daemon VM tests caught a migration regression the daemon-only
checks missed: the synthesized `response` events (get_state / get_messages /
get_available_models / set_model) dropped the `success: true` flag the panel's
`_handleResponse` requires, so the model picker / active-model / history were
silently dead while the reply stream still worked. Fixed (field restored) and
now guarded both daemon-side (`pi-remote-session` asserts `success=true`) and
end-to-end (`pi-chat-remote` asserts the panel learns its model via a new
`sessionModel` IPC probe — reverting the fix turns it red).

Remaining parity follow-ups (non-blocking): wire the `memory` extension/tool
(needs the sediment binary — a pi-chat concern); harden the daemon systemd unit.

---

## Landed (committed)

- [x] **Design + decisions** — `f2731d82`.
- [x] **Daemon `pi-sessiond`** — `dc7beebf`. `packages/pi-sessiond` (Bun/TS) +
  `modules/nixos/pi-sessiond`. Token-auth WS (`hello`→`welcome`),
  `create_session`→spawn `pi --mode rpc`, `command`→stdin, events fanned out
  with per-session `seq`, `attach`/`detach`. Verified by `checks/pi-remote-session`.
- [x] **Panel WS transport** — `2c2a0a2f`. `PiExecutor.qml` (one WS per
  executor) + `PiSession` dual-transport (local Process *or* WS when `executor`
  is set) + `PiChatBackend` wiring. Verified by `checks/pi-session-ws`.
- [x] **Module config** — `b3db7256`. `services.pi-chat.wsUrl`/`wsToken`;
  QtWebSockets on the panel's QML path.
- [x] **Reconnect + two-VM full-system test** — `a44de53f`. PiExecutor
  reconnect-with-backoff; `checks/pi-chat-remote` (server + desktop client,
  drives the panel against the remote daemon, screenshots the GUI).

What this proves: a chat client opens and drives a session on a remote
executor over WebSocket, end to end, GUI included — the **single-client happy
path** only.

---

## Missing — blockers (correctness / safety; do first)

- [x] **Per-session `systemd-run` sandbox in the daemon** (§2/§8) — **done.**
  `packages/pi-sessiond/sandbox.ts` wraps each session's pi in a `systemd-run`
  transient unit (`ProtectHome=tmpfs` when untrusted, narrowed `BindPaths`, the
  kernel/namespace protection set). Unit-tested by `checks/pi-sessiond-sandbox`;
  `checks/pi-remote-session` confirms pi still functions under the real sandbox.
- [ ] Run the sandboxed unit as a dedicated non-root uid (the daemon is root, so
  pi runs root-inside-sandbox). Needs state-dir ownership / `--uid=` wiring.
- [~] **Reconnect-with-history** (stage 3) — **partly done.** The daemon keeps
  a capped per-session event ring buffer and replays events with seq > lastSeq
  on `attach` (`packages/pi-sessiond/main.ts`), so a reconnecting/mirroring
  client catches up. Verified by the reconnect subtest in
  `checks/pi-remote-session`. Still missing:
  - [x] Disk persistence + cold respawn **done** — pi writes a durable
    `session.jsonl` (`--session-dir`, sandbox-bound); a session whose
    subprocess is gone is resurrected on `attach` by respawning
    `pi --continue` (provider/model from a `sessions/<id>.meta.json` sidecar,
    so it survives a daemon restart). Verified by `pi-remote-session`
    (jsonl-persisted + cold-resume subtests; `get_state` shows the reloaded
    history). `attach.sessionId` is UUID-validated before it touches the fs.
  - [x] Panel re-attaches its sessions on WS reconnect (sends `lastSeq`); the
    executor keeps subscribers across a drop and replays the gap on the next
    welcome (resets the high-water mark on a resurrected session). Verified by
    the drop→reconnect→catch-up flow in `checks/pi-session-ws`.
  - [ ] `get_messages` snapshot for history older than the buffer window.
- [~] **Lifecycle: idle-GC + subprocess ceiling — done.** A live-idle session
  with no clients is stopped after `idleTimeoutMs` (default 30min); `maxLive`
  caps resident subprocesses and evicts the idle LRU. Busy/parked sessions are
  never stopped; resurrection rides cold respawn-on-attach. Verified by
  `checks/pi-sessiond-lifecycle` (idle-GC + eviction, both with re-attach).
  Crash respawn is both lazy (a non-zero exit surfaces `session_exit`; the next
  attach resurrects) **and eager**: a crash with clients attached respawns in
  place (`--continue`, subscribers moved over) so a live mirror keeps streaming
  without a manual re-attach; a crash-loop guard (MAX_RESPAWNS within a window)
  then leaves it cold. Verified by `checks/pi-sessiond-sidechannel`
  (eager-respawn + crash-loop scenarios).
  - [x] ~~Reap pi units orphaned by a daemon restart~~ — **non-issue.** pi
    exits on stdin EOF, so a daemon restart closes each `systemd-run --pipe`,
    pi exits, and `--collect` removes the unit; nothing holds the session dir.
    Verified by the "resumes after a full daemon restart" subtest in
    `checks/pi-remote-session`.

## Missing — by stage

- [x] **Stage 1 deploy — done and superseded.** The loopback-executor topology
  was first validated by `checks/pi-chat-local-executor` (full desktop
  self-hosting `services.pi-sessiond` on `127.0.0.1`, panel attached over WS).
  The migration has since landed: the panel's local Process path is deleted,
  every desktop self-hosts the per-user `pi-sessiond-local` executor by default
  (`services.pi-chat.localExecutor`, default-on), and `checks/test-machine.nix`
  boots that shipping topology end-to-end — so the stage-1 check was removed as
  redundant (`pi-chat-remote` keeps covering panel → system `pi-sessiond`).
  The **client-side `tokenFile` is done** — `services.pi-chat.wsTokenFile`
  (+ a per-executor `tokenFile`) stages the `hello` token into
  `/run/spaces-secrets` (root:users 0640), read by the panel at connect time
  instead of from the world-readable config; verified by `checks/pi-session-ws`
  (token-from-file auth) + `checks/pi-chat-tokenfile-nix-eval`.
- [x] **Stage 2 — registry/n:m — done (daemon side).** `list_sessions` verb +
  `sessions` envelope merge live + cold sessions ({id, name, executor, state,
  updated}); `create_session.name` persisted in the meta sidecar. Multi-client
  mirroring (event/`response` fan-out to N clients on one session) verified.
  Covered by `checks/pi-remote-session` (list_sessions, cold-listing, two-client
  mirror). The *panel* side (consuming the registry / mirroring) is Stage 4.
- [~] **Stage 4 — multi-homing (panel) — done.** `services.pi-chat.executors`
  is a static list (id + WS url + token); the panel attaches to all of them at
  once (PiExecutor pool keyed by id) and pins each session to one via an
  `executor` field (the session list is keyed on `(executor, sessionId)`).
  `defaultExecutor` picks where new/legacy sessions land; `wsUrl`/`wsToken`
  remain a single-executor shorthand (back-compat). Each tab shows its executor.
  Verified by `checks/pi-chat-multihome` (a desktop pinned across two executors;
  each session streams from its own, screenshot shows the labelled tabs) +
  `pi-chat-remote` (single-executor back-compat). Remaining:
  - [x] Interactive new-session executor **picker** — the "+" button opens a
    popup of executors when more than one is configured (single-executor creates
    directly); selecting one pins the session via `newSession(name, executorId)`.
    Verified by `pi-chat-qmllint` + `pi-chat-multihome` (the pinning it drives);
    the click gesture itself is compositor-only (agent-vm).
  - [ ] Optional: discover *other* clients' sessions via `list_sessions` and
    merge them into the panel list (the daemon verb exists; the panel shows
    only its own sessions today).
- [~] **Stage 5 — side-channels + block-and-notify — mostly done.**
  `extension_ui_request` confirm/input/select/editor round-trips over the
  event/command plumbing; the daemon dedupes responses **first-answer-wins** and
  tells the other clients to collapse via `sidechannel_resolved` (the **panel
  now renders that** — the loser's confirm collapses); a request that fires with
  zero clients **parks** (idle-GC leaves it resident; replays on next attach)
  **and fires a notifier** (`services.pi-sessiond.notifyCommand`) so the user is
  reached out-of-band. Verified by `checks/pi-sessiond-sidechannel` (dedupe +
  park + notifier, real daemon + fake pi) and `checks/pi-session-ws`
  (panel collapse on `sidechannel_resolved`). Remaining:
  - [ ] `open_url` routed to the **active** client over WS — still a local UNIX
    socket (gated on the skill-config socket migration, a deferred decision).
  - [x] Zero-client *notify target*: an operator-supplied `notifyCommand` hook
    (ntfy/webhook/…), per the scope decision — **no** Signal/Matrix/ntfy chat
    adapter is built. (Web push from the PWA could be a later add.)
- [x] **Stage 6 — custom web client (PWA) — done.** Per the scope decision the
  only clients are the quickshell panel (WS) and a custom **PWA**; no external
  chat adapter. `packages/pi-web` is a vanilla-TS PWA (Bun-bundled, zero deps)
  served by the daemon on its own port; it connects over the §12 protocol,
  lists/creates/switches sessions, streams replies, renders + answers confirms
  (with `sidechannel_resolved` collapse), reconnects with `lastSeq` catch-up,
  and is installable (manifest + service worker). It mirrors a session
  alongside the panel (n:m). Verified: `checks/pi-web-reducer` (9 unit tests),
  `checks/pi-web-serve` (daemon serves the bundle), and a real-Chromium E2E this
  session (connect → prompt → reply; create/switch; reconnect), and locked in CI
  by `checks/pi-web-e2e` — a headless-chromium E2E (raw CDP-over-Bun, no npm)
  driving connect + streamed reply + confirm/Allow against the served PWA.
- [ ] **Stage 7 (deferred).** Mesh VPN; multi-user (more single-user executors).

## Deferred by explicit decision

- [ ] Transport security / TLS (token-only for now).
- [ ] skill-config store moving server-side.
- [ ] Session migration between executors (resume-from-committed when it lands;
  needs portable workspace identity — design §13 Q2).

---

## Test coverage gaps (code exists, no assertion)

- [~] Bad-token rejection; `tokenFile` path — the client `tokenFile` is now
  exercised (`checks/pi-session-ws` authenticates from a file; the module is
  covered by `pi-chat-tokenfile-nix-eval`). Bad-token rejection is still only
  via the fake daemon's check, not asserted directly.
- [ ] Reconnect (kill the daemon mid-session, assert recovery).
- [ ] Several sessions multiplexed over one connection (only one tested).
- [ ] n:m mirroring (2 clients, 1 session).
- [ ] Non-prompt commands over WS: `abort`, `set_model`, `get_available_models`,
  `new_session`/restart (only `prompt` exercised).
- [ ] `extension_ui` confirm over WS.
- [ ] Real-LLM round-trip over WS (every check uses the deterministic mock).

## Test environments

Have: cheap headless quickshell checks (no VM, ~seconds); 1-node + 2-node
`runNixOSTest`; `driverInteractive` (manual graphical REPL); single-VM `agent-vm`.

- [ ] **`agent-vm-server` / `agent-vm-client`** — interactive two-VM wrappers
  for clicking through the panel against a live remote daemon (reuse
  `packages/agent-vm/qmp.py`; the server/client host split already exists in
  `checks/pi-chat-remote.nix`).
- [ ] (optional) real-LLM remote variant (cf. `test-machine.nix`'s `--impure`
  openrouter mode), to exercise a real model over WS.

Everything else above (n:m, reconnect, sandbox, persistence) is a **new test in
an existing pattern** — no new environment type needed. Note: graphical
click-through must be run on a workstation with a display; the automated
`runNixOSTest` + screenshot is the headless-reproducible substitute.

---

## Recommended sequence

Each step is its own red→green increment with its own check (per `AGENTS.md`):

1. **Sandbox** + sandbox check — restores the safety property, unblocks stage 1.
2. **Persistence + reconnect-with-history** + kill/resume check.
3. **Crash respawn + idle-GC** + check.
4. **Stage 1 desktop deploy** (localhost executor; cutover decision).
5. **`list_sessions` + multi-homing** + merged-list / 2-client check.
6. **Side-channels + block-and-notify** + checks.
7. **Chat adapter / web-PWA**, then the deferred items.

Tooling (`agent-vm-server`/`agent-vm-client`) can land anytime it's useful for
manual GUI verification.
