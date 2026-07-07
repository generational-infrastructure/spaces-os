# Skill → integration migration: signal

**Status:** PLANNED (2026-07-07). Migrates the `signal` skill onto the
`spaces-integration-mcp` scaffold as the `integration-signal` MCP server,
following the mail/caldav/contacts pattern
([agent-integrations-skill-migration-plan.md](./agent-integrations-skill-migration-plan.md)).
Architecture: [agent-integrations-design.md](./agent-integrations-design.md);
POC record: [agent-integrations-poc-plan.md](./agent-integrations-poc-plan.md).

All design questions were resolved in a grilling session; the decisions below
are final. Marketplace signal MCP servers were evaluated and rejected
(first-party build).

## Current architecture (what exists today)

- `modules/nixos/signal-cli.nix` — `services.spaces-signal`:
  - `spaces-signal-cli.service`: signal-cli daemon, JSON-RPC on
    `%t/signal-cli/socket`, identity keys in `~/.local/share/signal-cli`
    (0700, never agent-reachable). Units `ConditionPathExistsGlob`-gated on a
    linked account (`%h/.local/share/signal-cli/data/*.d`).
  - `spaces-signal-bridge.service`:
    `packages/signal-cli/spaces_signal/bridge.py` — subscribes to the daemon,
    persists envelopes into `~/.local/state/spaces/signal/messages.db`;
    enqueue socket (`%t/spaces-signal/sandbox/enqueue.sock`, agent-reachable)
    + panel socket (`%t/spaces-signal/panel.sock`, not agent-reachable)
    implement a bespoke pending-token send-approval flow (`pending_sends`
    table, TTL, caps).
  - Sandbox grants to the agent: store dir ro,
    `~/.local/share/signal-cli/attachments` ro, sandbox runtime dir rw;
    `sandboxEnv.SPACES_SIGNAL_DB`; bash-confirm allowlist `^signal(\s|$)`.
- `packages/signal-cli/spaces_signal/cli.py` — agent-facing `signal` CLI
  (threads/read/search/contacts/groups/send).
- `skills/signal/SKILL.md`; `builtinSkills.signal` gated on
  `services.spaces-signal.enable` in `modules/nixos/pi-chat/default.nix`.
- Panel: `SignalConfirm.qml` + banner in `Panel.qml` + `PiChatBackend.qml`
  wiring + `signal-*` i18n keys in all locales.

## Target architecture

`integration-signal` MCP server (Python, `spaces-integration-mcp` scaffold,
pattern: `packages/integration-contacts/`) in its own Landlock domain. The
agent reaches it only via gateway typed tools. Send approval moves to the
gateway `approval_request` path (already rendered by the panel).

DELETED: agent `signal` CLI, the skill, enqueue+panel sockets, the
`pending_sends` machinery, `SignalConfirm.qml`. The bridge slims to
forwarder-only (daemon → messages.db). The signal-cli daemon + identity
handling are unchanged; the QR link flow stays manual (out of scope).

## Locked decisions (grill record — do not relitigate)

1. **Tool surface**: `threads`, `read_thread`, `search` (messages.db);
   `contacts`, `groups` (daemon JSON-RPC); `note_to_self` (daemon send to own
   account); `send` (daemon send); `fetch_attachment`; `send_preview`
   (gateway-only, see 5). autoRun = everything except `send` (confirm) and
   `send_preview` (never listed/autoRun).
2. **`send{recipient, name, body}`, name REQUIRED, dispatch-time
   verification**: the integration resolves `recipient` against daemon
   contacts/groups; the stored display name (after `sanitize_display`) must
   match `name` or the send REFUSES with an error carrying the true name (+
   near-miss candidates). Approval-of-a-lie approves a no-op; an honest retry
   produces an honest re-prompt.
3. **Strict recipients**: only known contacts / joined groups. Unknown phone
   numbers / usernames refuse ("not in your contacts — add them on your
   phone"). No escape hatch.
4. **Groups**: `name` = group title, verified identically. The similarity
   scan pools contacts ∪ group titles in ONE namespace. The preview always
   labels the kind: `to: GROUP "X" (14 members)` vs `to: Name <+phone>`.
5. **Gateway `confirmPreview` hook** (new gateway feature, lands first): the
   manifest/definition gains per-tool `confirmPreview: "<preview-tool>"`.
   Before raising `approval_request` for such a tool, the gateway calls the
   preview tool (same args) over MCP; the result text goes into the approval
   payload as `context`; the panel renders it as untrusted quoted text (no
   markup). Preview failure/timeout ⇒ FAIL CLOSED for that tool (the tool
   errors, no approval raised). Confirm tools WITHOUT `confirmPreview` (mail
   `message_send`, caldav `put`…) keep today's semantics.
6. **`send_preview` content**: trusted `to:` line (resolved name + raw
   id/number, kind, member count for groups) + similarity warnings against
   the pooled namespace. Similarity = sanitize → NFKC + casefold → small
   Latin/Cyrillic/Greek confusable-skeleton fold (UTS#39-lite, stdlib only) →
   Levenshtein ≤ 2 (or normalized ≤ 0.25 for short names). Skeleton-equal
   entries marked "⚠ confusable (mixed-script)", others "similar"; raw ids
   beside every candidate. WARN-ONLY — never blocks dispatch; only
   name-mismatch (decision 2) refuses.
7. **Attachments**: the grant moves to the integration domain. `read_thread`
   returns attachment ids/filenames; `fetch_attachment{message_uid, index}`
   (autoRun) copies the file into `$SPACES_INTEGRATION_SHARED_DIR`, returns
   the path; the agent reads it natively (github `clone_to_workspace`
   file-exchange pattern). Stored-filename path traversal neutralized
   (basename only).
8. **messages.db access**: the integration queries SQLite directly, reusing
   `spaces_signal/db.py` read helpers. The Landlock grant on the store dir is
   rw ONLY to satisfy WAL side-files; the connection opens `mode=ro` URI,
   code-enforced, with a test pinning that writes raise. If `db.py` turns out
   non-WAL (check at red-test time), use an ro grant instead.
9. **Field-less enable (broker change)**: signal declares
   `config={}, secrets={}`. Today `enable` refuses (`storeProfiles` → zero
   profiles → "no complete profile",
   `packages/spaces-integrationd/{server.go,store.go}`). The broker must skip
   the completeness gate AND credential staging when the definition has no
   fields (lib.nix already emits no `LoadCredential*` then). Go test:
   field-less definition enables; `list` shows empty schemas. The panel
   bridge check gains a field-less fixture (enable button active without
   profiles).
10. **`note_to_self`**: autoRun, no `name` arg, no preview (matches today's
    ungated self-send).
11. **Unlinked/daemon-down**: EVERY tool probes daemon-socket reachability
    first; unreachable ⇒ a uniform onboarding error (the
    `signal-cli link -n …` hint), including DB-backed tools (an empty store
    must not masquerade as "no messages"). Test: fixture DB + no daemon
    socket ⇒ `threads` errors with the hint.
12. **`extraPaths` manifest mechanism** (new, generic): a list of
    `{source, mode}` folded into the Landlock policy by
    `spaces-landlock-policy`; eval-checked in `spaces-integrations-nix-eval`.
    Signal uses it for: `%t/signal-cli` (rw, socket connect), the store dir
    (per decision 8), `%h/.local/share/signal-cli/attachments` (ro). Signal
    manifest: `network=false`, `connectPorts=[]` (first no-network
    integration; the daemon does the internet).
13. **Enablement**: shipped as a module default in
    `modules/nixos/spaces-integrations/defaults.nix` (all 5 integrations); the
    user enables once in the panel; NO auto-enable (req-11).
    `services.spaces-signal` keeps managing daemon+bridge units (inert until
    linked).
14. **Agent `signal` CLI deleted** (`spaces_signal/cli.py` + tests + bin
    entry); the upstream `cfg.package` signal-cli stays on PATH for
    link/debug.
15. **Marketplace rejected**: rymurr (3 tools), googlarz (2★, 72 tools),
    foxl-ai (stdio-only = banned §3B, AGPL). First-party wraps existing
    tested backends; a later swap-in stays cheap (§3D wraps unmodified
    servers).

## The steps

One `jj` commit per step; red-green-refactor TDD per `AGENTS.md`.

### Step 1 — Gateway `confirmPreview` + `approval_request.context`
`packages/pi-sessiond/integrations.ts` (+ `.test.ts`); definition JSON in
`modules/nixos/spaces-integrations/lib.nix`; extend the `pi-session-approval`
check (fake daemon): context rendered; preview failure fails closed. The
panel renders `context`; new i18n keys in ALL 11 locales.

### Step 2 — `extraPaths`
`lib.nix` + the `spaces-landlock-policy` CLI; red test in
`checks/spaces-integrations-nix-eval` asserting the grant appears in the
policy spec and the posture stays deny-by-default.

### Step 3 — Broker field-less enable
Decision 9; Go tests in `packages/spaces-integrationd/` (tests drive the
REAL skill-config).

### Step 4 — `packages/integration-signal/`
Scaffold `make_server` records (shape: `integration-contacts`; ships
`schema.json` with empty config/secrets + tools list;
`checks/spaces-integrations-schema-sync` pins the manifest against it).
Pytest against a fake daemon socket + fixture messages.db: recipient
classification, name mismatch refusal + true-name error, strict
unknown-recipient refusal, pooled-namespace similarity + confusable cases
(Cyrillic/Greek), preview purity (no `send` JSON-RPC during preview),
self-recipient refusal in `send` (route to `note_to_self`), unlinked hint,
`fetch_attachment` staging + traversal neutralization, db `mode=ro` pin.

### Step 5 — Bridge slim-down
Delete enqueue/panel listeners + `pending_sends` + TTL/caps from
`bridge.py`/`db.py`; shrink `test_bridge.py`/`test_db.py`; forwarder tests
stay green.

### Step 6 — Cutover
Declare as a module default in `modules/nixos/spaces-integrations/defaults.nix` (autoRun split per
decision 1, `confirmPreview.send = "send_preview"`); strip from
`signal-cli.nix`: `sandboxAllowedPaths`, `sandboxEnv`, bash-confirm
`^signal(\s|$)`, `signalCliPkg` from systemPackages; drop
`builtinSkills.signal` in `pi-chat/default.nix`; delete `skills/signal/`,
`cli.py`+tests; panel: delete `SignalConfirm.qml`, the `Panel.qml` banner,
`PiChatBackend.qml` wiring, `signal-*` i18n keys from ALL locales.

### Step 7 — Approval-split driver check
Pattern `checks/pi-session-approval`: `send` raises confirm with preview
context; `threads`/`note_to_self` don't. Do NOT extend
`checks/test-machine.nix`.

### Step 8 — Optional agent-vm smoke
Only if the fake-gateway check can't cover the panel wiring.

## Risks (recorded, accepted)

- The integration domain holds the daemon socket = full account power;
  signal is trusted-tier first-party code (the bridge had the same
  property). The gateway confirm is the only send gate.
- Renamed-existing-contact attack (attacker renames an existing conversation
  partner to "Mom"): the similarity scan can't see it (only one "Mom"
  exists). Needs name-change-history pinning; OUT OF SCOPE.
- AF_UNIX connect not Landlock-mediated (POC residual) — unchanged posture;
  the daemon socket was never agent-granted.
- Group titles are member-controlled; the member count in the preview is the
  fan-out cue.
