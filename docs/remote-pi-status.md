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

- [ ] **Per-session `systemd-run` sandbox in the daemon** (§2/§8). pi currently
  spawns *unsandboxed* → a **regression vs. today's desktop panel** and a hard
  blocker for any desktop cutover. Port the `PiSession._buildCommand` bouquet
  (`ProtectHome=tmpfs`, narrowed `BindPaths`/`BindReadOnlyPaths`, the `trusted`
  flag) into the daemon's spawn.
  - Test: `checks/pi-sessiond-sandbox` asserting the spawned pi is confined
    (mirror the existing `pi-session-sandbox-*` checks).
- [ ] **Persistence + reconnect-with-history** (stage 3). `--session-dir` +
  `--continue`; per-session ring buffer (≥ current turn); `snapshot` (from
  `get_messages`) on cold attach; `lastSeq` warm-reattach replay. Today:
  `--no-session`; reconnect re-attaches but loses history and any in-flight turn.
  - Test: kill/respawn the daemon mid-turn; client reattaches and catches up.
- [ ] **Crash respawn + idle-GC + subprocess ceiling.** Respawn with
  `--continue` on non-zero exit; GC idle/cold sessions after a timeout; cap
  resident subprocesses; never GC a busy/parked session.

## Missing — by stage

- [ ] **Stage 1 deploy.** A host config that runs pi-sessiond on `localhost`
  and points the desktop panel at `ws://127.0.0.1:<port>` (gated on the
  sandbox). Decide: keep dual-transport, or cut the local Process path.
- [ ] **Stage 2 — registry/n:m.** `list_sessions` daemon verb + `sessions`
  envelope; multi-client mirroring (event/`response` fan-out to N clients on one
  session). Single-session multiplexing already works; mirroring + `list_sessions`
  do not.
- [ ] **Stage 4 — multi-homing.** Static executor list in the panel (id + WS
  address + token); attach to local *and* server simultaneously; merged session
  list keyed on `(executor, sessionId)`; `executor` field on `create_session`.
  Panel currently holds exactly one executor.
- [ ] **Stage 5 — side-channels + block-and-notify.** Route
  `extension_ui_request` confirm/input/select/editor (first-answer-wins +
  `sidechannel_resolved`), `open_url` to the active client, `notify` broadcast;
  park when zero clients; notifier. Today `skill-config request-input` and
  `open_url` are **local UNIX sockets** that don't reach a remote daemon
  (`confirm` *might* round-trip over WS but is untested).
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
