# Agent-integrations POC — implementation plan

**Status:** ready to implement. Architecture + contract locked in a grilling
session (2026-06-30); both build-gates verified on the target host. This is the
execution record for the §9 POC in
[agent-integrations-design.md](./agent-integrations-design.md) — read that for
the architecture and option-space rationale; read this for *what was decided,
what was verified, and the order of work*.

**Scope:** one real integration (**GitHub**) end to end, every load-bearing
mechanism exercised once: the user-scoped TPM2 secret path, the same-uid
Landlock wall, per-call approval, runtime tool discovery, and text **+ file**
exchange.

## Verified environment (build-gates)

Probed on the target host as uid 1000, via `pueue` (runs outside the agent
sandbox):

| Fact | Value | Implication |
|---|---|---|
| systemd | 260.2, `+TPM2` | user-scoped creds available |
| kernel | 6.18.28 | Landlock **ABI 6** (full IPC scoping) ✅ |
| active LSMs | `capability,landlock,yama,bpf,ima` | Landlock enforced ✅ |
| TPM2 | `/dev/tpm0`, `/dev/tpmrm0`, `has-tpm2` → yes | sealing available ✅ |
| `encrypt --user --uid=self --with-key=tpm2` | ❌ `Selected key not available in --uid= scoped mode` | pure `tpm2` unusable user-scoped (the §8 bug, live on 260) |
| `encrypt --user --uid=self --with-key=host+tpm2` | ✅ 568-byte blob; decrypt round-trips; wrong `--name` rejected | **the secret path** |

**Resolution — use `--with-key=host+tpm2`.** It enforces the TPM (both
components mandatory to decrypt — *not* the insecure `auto` fallback the design
forbids) *and* carries the host-key / uid / machine-id binding that pure `tpm2`
lacks — which is exactly why pure `tpm2` cannot bind to a uid and is rejected in
`--uid=` mode. Cross-user isolation holds even with `tss` membership: the
host-key + uid component is gated by the root `systemd-creds.socket`
`SO_PEERCRED` uid-check, which a `tss` user cannot forge (a pure-`tpm2` blob, by
contrast, *would* be unsealable by any `tss` user — another reason to avoid it).
The probe ran as a `tss`-group user; integration users get `tss` at onboarding,
which makes the encrypt side deterministic.

## Locked decisions

1. **Salvage by rebuild, not rebase.** `integrations-poc` (`qssukqpz c143fd89`)
   predates the Landlock pivot, the per-user refactor, and the rename. Build
   fresh on the current commit; pull file *contents* as reference per step. One
   `jj` commit per step.
2. **Materialiser = NixOS module** `modules/nixos/spaces-integrations/` emitting
   `systemd.user.services."spaces-integration-<name>"` + `.socket` (the repo has
   no home-manager; this mirrors the `pi-sessiond` module). Lowering lives in a
   **backend-agnostic `lib.nix`**; `default.nix` is a thin NixOS adapter, so a
   home-manager adapter can reuse `lib.nix` later.
3. **One policy emitter.** Reuse `buildLandlockPolicy`
   (`packages/pi-sessiond/sandbox.ts`); never write a second Nix emitter of the
   landlockconfig schema.
4. **Policy lowered at unit start.** User-unit paths (`StateDirectory`,
   `$CREDENTIALS_DIRECTORY`, shared dir) resolve only at unit start, a system
   module emits one generic user unit (no build-time `$HOME`), and landlockconfig
   variables are in-document Cartesian templating, not env injection. So a thin
   `spaces-landlock-policy` CLI (wrapping `buildLandlockPolicy`) runs in
   `ExecStartPre`, writes `$RUNTIME_DIRECTORY/landlock.json`, and `ExecStart` is
   `pi-landlock-exec --json $RUNTIME_DIRECTORY/landlock.json -- <cmd>`. `lib.nix`
   emits the static **policy spec** (buckets / ports / abi / scope), eval-checked.
5. **Tool contract = runtime discovery + manifest allowlist.** The gateway runs
   `initialize` + `tools/list` against the (untrusted) MCP server and registers
   typed tools dynamically; schemas come from the server (*presentation only* —
   they gate nothing; the args-bound confirm is the barrier). The manifest
   declares an **`autoRun` allowlist**; non-allowlisted tools are callable but
   **confirm-per-call**. Empty allowlist ⇒ a freshly-plugged server is
   all-confirm, so unmodified MCP servers plug in with zero schema
   transcription. MCP annotations (`readOnlyHint`…) are untrusted UI hints only.
6. **Confirm prompt = {Allow once · Allow for this session · Deny}.** "Session"
   is an ephemeral, tool-name-scoped grant in the gateway's per-session state.
   **Allow-forever and args-bound finer grants are deferred** — `enabled.json`
   records only which integrations are enabled, not tool grants.
7. **Broker = separate `--user` `spaces-integrationd`** (Go; salvage the
   branch's), on `%t/spaces-integrations.sock`, `SO_PEERCRED`-authed, user-scoped
   `host+tpm2` creds. Coexists with `skill-config-daemon` (removed *after* the
   POC). Two prompt paths: **enable / secret** = panel→broker direct; **tool
   approval** = gateway→panel over the existing pi-sessiond executor WebSocket
   (new `approval_request` event, rendered like `SignalConfirm.qml`).
8. **`tss` at onboarding.** Integration users get
   `users.users.<name>.extraGroups = [ "tss" ]` as part of the one-time
   account + linger onboarding host action. Residual risk is at most TPM DoS /
   application-PCR, never secret theft (host+tpm2 uid-binding holds). Keeps
   req-10 — *using* an integration stays rootless.
9. **File exchange in-scope** (not deferred): a per-pair shared dir granted to
   both the integration policy **and** the agent's session policy;
   `clone_to_workspace` delivers a tree the agent edits with its native tools.
   Sequenced after the core wall is proven — it extends the *shipped* session
   sandbox (`main.ts`/`sandbox.ts`).
10. **Secret key = `host+tpm2`**, never pure `tpm2`, never `auto`.

## Salvage map (from `integrations-poc` `qssukqpz c143fd89`)

| Branch artifact | Action |
|---|---|
| `packages/spaces-integrationd/` (Go: protocol/server + 347-LoC test) | **salvage**; switch creds to `--user --uid=self --with-key=host+tpm2`, drop root |
| `packages/integration-github/` (Python MCP + tests) | **salvage**; already socket-activated + reads `$CREDENTIALS_DIRECTORY` |
| `packages/pi-sessiond/integrations.ts` (+test) | **rewrite** onto the current `main.ts`/`rpc-driver.ts`; add runtime discovery + allowlist |
| `modules/nixos/spaces-integrations{,-bundled}.nix` | **rewrite** as `modules/nixos/spaces-integrations/{lib.nix,default.nix}` emitting `systemd.user.services` (branch used system `DynamicUser`) |
| `checks/{spaces-integrations-nix-eval,pi-sessiond-integration-gateway,integration-poc-machine}` + Python drivers (mock-llm, stub-integration, mock-github-api, mcp/broker clients) | **salvage drivers**; rewire asserts to same-uid Landlock + `host+tpm2` + allowlist |
| panel QML (`SettingsWindow.qml`, `PiChatBackend.qml`, i18n×12) | **salvage as reference**; reconcile with the current panel + the new `approval_request` event |

## Key existing code to build on

- Supervisor: `packages/pi-sessiond/{main.ts,sandbox.ts,proxy.ts,rpc-driver.ts}`
  — `sandbox.ts` exports `buildLandlockPolicy(SandboxPolicy)`; `main.ts`
  `writeLandlockPolicy` builds the per-session policy at runtime.
- Launcher: `packages/pi-landlock-exec/` — `--json <policy>` (repeatable),
  composes + `restrict_self()` + exec; `.resolve()` handles in-document
  variables only.
- User-unit + `lib.nix` precedent: `modules/nixos/pi-sessiond/{default.nix,lib.nix}`.
- Daemon + panel-IPC precedent: `packages/skill-config-daemon/` +
  `systemd.user.services.spaces-skill-config-daemon` on `%t/spaces-skill-config.sock`;
  panel client `programs/pi-chat/{PiChatBackend.qml,PiSession.qml}`; confirm UI
  `programs/pi-chat/SignalConfirm.qml`.
- landlockconfig doc shape:
  `{ abi:6, ruleset:[{scoped:["signal","abstract_unix_socket"]}], pathBeneath:[{allowedAccess,parent}], netPort:[{allowedAccess:["connect_tcp"],port}] }`;
  `buildLandlockPolicy` folds in `/nix/store` (rx) + `/etc` (DNS/ssl) + `/dev`
  defaults.

## The 7 steps

One `jj` commit each. (This commit = doc alignment / decision capture; the steps
below remain.)

1. **Nix codegen.** `modules/nixos/spaces-integrations/{lib.nix,default.nix}`,
   the `spaces-landlock-policy` CLI (wrapping `buildLandlockPolicy`, shipped with
   the `pi-sessiond` package), and `checks/spaces-integrations-nix-eval`.
   - `lib.nix`: manifest → { unit data, socket data, policy spec, definition JSON }.
   - `default.nix`: `services.spaces-integrations.integrations.<name>` →
     `systemd.user.services` (ExecStartPre policy gen, ExecStart `pi-landlock-exec`,
     `StateDirectory`, `LoadCredentialEncrypted`, hardening) + `.socket`.
   - **Acceptance:** unit-text asserts; running the CLI on sample resolved paths
     yields a deny-by-default policy granting exactly StateDir (rw) + cred mount
     (ro) + declared ports, nothing else.
2. **Broker.** `packages/spaces-integrationd/` `--user` daemon + Go protocol
   tests.
   - **Acceptance:** `set-secret` encrypts `host+tpm2` and discards plaintext;
     `enable` writes `enabled.json`; `SO_PEERCRED` rejects other uids.
3. **Demo integration.** `packages/integration-github/`: `initialize` /
   `tools/list` / `tools/call` on the activated fd; PAT from
   `$CREDENTIALS_DIRECTORY/token`; `get_repo` (read), `create_issue` (effect).
   - **Acceptance:** pytest; `socat`-drive the socket end to end before pi.
4. **Gateway.** `packages/pi-sessiond/integrations.ts` — discovery + `autoRun` /
   confirm on the supervisor; cheap pi-session check.
   - **Acceptance:** allowlisted tool ⇒ no prompt; non-allowlisted ⇒ confirm with
     args; "session" suppresses repeats that session; Deny ⇒ "Denied by user." +
     server never called; no integrations env ⇒ no integration tools.
5. **Panel.** Enable + secret form (panel→broker direct, rendered from the
   definition JSON) + `approval_request` event (gateway→panel ws), confirm
   component {once, session, deny}; all i18n locales updated.
6. **File exchange.** Per-pair shared dir granted to both the integration policy
   (`lib.nix` policy spec) **and** the agent session policy (supervisor adds
   enabled integrations' shared dirs to `writeLandlockPolicy`);
   `clone_to_workspace`; agent edits the tree natively; push/PR behind approval.
   - **Acceptance:** cheap check that the session policy includes the shared dir
     when an integration is enabled; e2e in the VM.
7. **VM check.** `checks/integration-poc-machine` — swtpm + alice/bob (both in
   `tss`), GitHub API mocked. Asserts the full matrix: enable refused without
   secrets; at-rest ciphertext only; instance sees plaintext
   (`secret_fingerprint`); other user can't decrypt; integration auths to the
   mock with the token (Authorization observed); agent Landlock domain cannot
   `ptrace`/read/open the integration's socket / `StateDirectory` / cred mount
   while the supervisor can; alice can't reach bob's socket / `StateDirectory`;
   normal user enable→provision→launch e2e; `host+tpm2` encrypt succeeds as the
   non-root user; file exchange (clone → agent edits → PR behind approval).

## Open residuals / deferred

- **Non-`tss` socket-only encrypt path** — avoided by granting `tss`; could be
  verified later to drop `tss` for tighter least-privilege.
- **Allow-forever + args-bound finer grants** (req-8 shape) — deferred;
  `enabled.json` is ready to grow.
- **Per-host network proxy** (§3F) — deferred; `network` is bool egress for now.
- **Agent-proposed enable** (§5.6), **foreign-setup / QR channel** (§5.5),
  **output screening**, **container/microVM tiers**, **OAuth** — out of POC
  scope (§9.5).
- **pi SDK MCP client** — irrelevant; the gateway owns the MCP side either way.
- **Integration-socket peer-auth** — `AF_UNIX connect()` is not Landlock-mediated
  and ABI-6 IPC scoping covers only abstract sockets, so a same-uid agent that
  learns an integration's pathname activation socket could connect directly and
  bypass the gateway's approval. The POC relies on FS isolation + path
  non-disclosure + the gateway as the sole approval point; a peer/credential
  check on the socket would close the direct-connect path.

## Implementation notes — deviations & decisions

Recorded as the POC was built (2026-06-30). Captures where the work departed
from the plan above, the compromises taken, and the load-bearing decisions made
along the way — including two latent bugs the full-system VM check (step 7)
surfaced that earlier, narrower checks could not.

### Latent bugs the VM surfaced (fixes reached back into earlier steps)

- **Gateway socket naming.** The gateway derived an integration's socket as
  `<socketDir>/<name>.sock`, but the materialiser emits
  `%t/spaces-integration-<name>.sock`. The cheap gateway check and the
  `integrations.test.ts` unit tests both stubbed the bare-name path, so the
  mismatch stayed invisible until the VM wired the real gateway to the real
  unit. Fixed by teaching `buildRegistry` the unit-naming convention
  (`socketDir = %t`, socket = `spaces-integration-<name>.sock`); the two stub
  tests were updated to match.
- **Broker `systemd-creds` / `systemctl` invocation dropped its arguments.**
  The broker unit passed the multi-word `systemd-creds encrypt …` and
  `systemctl --user` commands through a `serviceConfig.Environment` *list*,
  whose values systemd splits on whitespace — so the broker received only the
  bare binary path and ran `systemd-creds … -` (parsing `-` as the verb). The
  broker's Go test mocks the encrypt/systemctl command, so it never exercised
  the real argument vector. Fixed by moving the broker's environment to the
  unit `environment` attrset (which NixOS quotes); the nix-eval check now reads
  the values from `.environment`.

### Architectural decisions

- **`pi-sessiond` ↔ `spaces-integrations` module wiring.** Making the gateway
  discover integrations on a real system needs the daemon unit to carry
  `SPACES_SESSIOND_INTEGRATIONS_{ENABLED,DEFS,SOCKETS,SHARED}`. The `pi-sessiond`
  module now sets them when `services.spaces-integrations.enable` (a cross-module
  read, `or false`-guarded so the option's absence is harmless on deployments
  without the integrations module). This glue was not a numbered step; it is the
  prerequisite that turns the per-step pieces into a working whole.
- **Daemon `ProtectHome` is relaxed to `read-only` when integrations are on.**
  `ProtectHome=tmpfs` empties `/home` *and* `/run/user` for the supervisor, which
  hides the broker's `enabled.json` (under `/home`) and every integration's
  socket + shared dir (under `/run/user`) — so the gateway saw zero integrations.
  The per-integration socket paths are created at runtime and are not known when
  the unit starts, so the existing `BindPaths` punch-through could not cover them
  cleanly. When integrations are enabled the daemon drops to
  `ProtectHome=read-only`: it can read `enabled.json`, `connect()` the sockets,
  and grant the shared path, but still cannot write the user's files, and each
  per-session pi child keeps its own Landlock domain regardless. The daemon never
  needs to *create* the shared dir — discovery (run before the WS listens)
  activates each integration, whose `ExecStartPre` makes the dir first.

### VM check (step 7) realisations

- **File exchange is driven by real pi + a scripted mock LLM.** The VM runs the
  real pi child and the `spaces-integrations` extension; a mock OpenAI endpoint
  scripts the tool-call chain (`get_repo` → `clone_to_workspace` → a native edit
  → `open_pull_request`) and a WebSocket driver auto-approves the two
  confirm-gated tools. "The agent edits the tree with its native file tools" is a
  `bash` tool call (allowlisted via `bashConfirm.allowPatterns` so it auto-runs)
  writing into the granted shared workspace; `open_pull_request` then reflects
  that file into the PR body, proving the round-trip end to end.
- **GitHub is redirected with a wrapper, not a module option.** The integration
  reads `SPACES_GITHUB_API_URL` from its environment. Rather than add a
  per-integration `environment` knob to the module, the VM points the integration
  at the in-VM mock with a `writeShellScript` wrapper used as its `command`; the
  integration package and the `services.spaces-integrations` contract are
  untouched.
- **Cross-user DAC is exercised bob→alice.** The wall is symmetric uid DAC plus
  user-scoped credentials, so the VM provisions only `alice` (running both
  `pi-sessiond` and the broker — giving `bob` linger too would collide on the
  daemon's loopback port) and asserts that `bob`, a sibling in the *same* `tss`
  group, cannot read alice's ciphertext or reach her broker socket. "Other users
  cannot decrypt" is established by that DAC read-denial together with the
  `--uid=self` binding (asserted in the nix-eval check), without standing up a
  second user manager.
- **The Landlock-wall probe tests the FS wall with the live session's real
  policy.** It re-applies the actual `landlock.json` the supervisor wrote for the
  e2e session (through `pi-landlock-exec`) rather than a hand-rolled policy, so it
  tests exactly the domain a real agent runs under: the integration's private
  runtime state is denied while the granted shared workspace stays reachable.
  **Finding:** Landlock mediates filesystem opens, **not** `AF_UNIX connect()`
  (and ABI-6 IPC scoping covers only *abstract* sockets, not the integration's
  pathname activation socket), so the wall the VM asserts is FS isolation of the
  integration's private state — not socket unreachability. See the
  integration-socket peer-auth residual above.
- **Determinism.** `alice`/`bob` uids are pinned (1001/1002) so the shared
  workspace path the scripted edit writes is fixed.
