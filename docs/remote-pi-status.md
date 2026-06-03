# Remote pi — implementation status & continuation plan

Living execution tracker for the remote-pi build. Rationale and the staged
plan live in [`remote-pi-design.md`](./remote-pi-design.md); "stage N" below
refers to its §14. Update this file as work lands.

All work is on branch **`pi-remote-chat`** (not pushed). Checks run with
`nix build .#checks.x86_64-linux.<name>`.

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

- [~] **Stage 1 deploy — validated.** `checks/pi-chat-local-executor` boots a
  full desktop that self-hosts `pi-sessiond` on `127.0.0.1` with the panel at
  `ws://127.0.0.1:8770`, and drives a sandboxed session end-to-end (daemon +
  panel coexisting on one machine). Decision: **keep dual-transport** — the WS
  path doesn't yet carry skill-config / side-channels, so cutting the local
  Process path would regress the desktop. Remaining: a one-flag bundle toggle
  + a `wsToken` tokenFile indirection (loopback token is world-readable today),
  flipped on once side-channels land.
- [x] **Stage 2 — registry/n:m — done (daemon side).** `list_sessions` verb +
  `sessions` envelope merge live + cold sessions ({id, name, executor, state,
  updated}); `create_session.name` persisted in the meta sidecar. Multi-client
  mirroring (event/`response` fan-out to N clients on one session) verified.
  Covered by `checks/pi-remote-session` (list_sessions, cold-listing, two-client
  mirror). The *panel* side (consuming the registry / mirroring) is Stage 4.
- [ ] **Stage 4 — multi-homing (panel).** Static executor list in the panel (id
  + WS address + token); attach to local *and* server simultaneously; merged
  session list keyed on `(executor, sessionId)`; `executor` field on
  `create_session` (daemon already accepts/ignores it). Panel currently holds
  exactly one executor; the daemon `list_sessions`/mirroring it needs now exist.
- [~] **Stage 5 — side-channels + block-and-notify — daemon routing done.**
  `extension_ui_request` confirm/input/select/editor round-trips over the
  event/command plumbing; the daemon dedupes responses **first-answer-wins**,
  collapses the prompt on the other clients via `sidechannel_resolved`, and
  **parks** a session whose request fired with zero clients (idle-GC leaves it
  resident; the request replays on the next attach). Verified by
  `checks/pi-sessiond-sidechannel` (real daemon + fake pi, no VM). Remaining:
  - [ ] External **notifier** for true zero-client delivery (the Stage 6 chat
    adapter doubles as it); today a parked request just waits for an attach.
  - [ ] `open_url` routed to the **active** client; `notify` semantics.
  - [ ] Panel renders `sidechannel_resolved` (collapse the loser's bubble).
  - [ ] `skill-config request-input` / `open_url` are still **local UNIX
    sockets** that don't reach a remote daemon (skill-config server-side is a
    deferred decision).
- [ ] **Stage 6.** Chat adapter (Signal/Matrix/ntfy; doubles as the notifier) +
  web UI / PWA.
- [ ] **Stage 7 (deferred).** Mesh VPN; multi-user (more single-user executors).

## Deferred by explicit decision

- [ ] Transport security / TLS (token-only for now).
- [ ] skill-config store moving server-side.
- [ ] Session migration between executors (resume-from-committed when it lands;
  needs portable workspace identity — design §13 Q2).

---

## Test coverage gaps (code exists, no assertion)

- [ ] Bad-token rejection; `tokenFile`/credential-dir path (tests use an inline token).
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
