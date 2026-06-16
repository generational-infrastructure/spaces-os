# Design: secure agent integrations

**Goal:** let the agent use external services and desktop resources
(email, calendar, browser, screenshots, GitHub, system management, …)
through *integrations*, under these constraints:

1. The agent can **never** read secrets — secrets must not end up in
   model context.
2. Integrations cannot access each other's secrets, data, or state
   (the bar is untrusted third-party code, e.g. mcpmarket.com servers).
3. First access to a secret requires an explicit user grant
   (allow-once or whitelist).
4. An integration can mark operations as requiring per-call user
   approval (e.g. "send this email?").
5. Least privilege: an integration only reaches the resources it needs.
6. Manifest-driven permissions, approved by the user when enabling an
   integration.
7. Agent ↔ integration communication carries **text and files**.
8. (Soft) temporary resource grants to an integration.
9. **All configuration — including secrets — is entered through the
   GUI.** No clan vars, no sops, no hand-edited TOML. The panel is the
   only provisioning surface.
10. **No root, no rebuild to *use*.** A user builds, enables, launches,
    and configures integrations entirely from their own session
    (home-manager-style) — no `nixos-rebuild switch`, no per-integration
    root action. One one-time, system-wide platform prerequisite set by
    root (§7) is acceptable.
11. **Agent-proposed, user-gated enablement.** The agent may *propose*
    enabling an integration; it can never enable one itself. The user
    accepts in the panel (this is the req-6 manifest approval), after
    which the integration is permanently available across sessions.

**Prerequisite — runtime isolation.** This design assumes the pi runtime
itself runs sandboxed: the model loop, tools, and extensions inside a
per-session `--user` `managed`-userns service, driven by a thin trusted
supervisor (what `pi-sessiond` becomes). Without it, model-steerable code
— notably pi extensions and the in-process file tools — runs bare as
uid 1000 and owns every integration namespace, voiding req 1. It lands
first: [pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md).

## TL;DR

Anything in the agent's execution domain (same uid, reachable fs) is
agent-controlled: it can read the files, `LD_PRELOAD`, `ptrace`, or read
`/proc/<pid>/mem` of any helper. A CLI that "doesn't print the secret"
is no protection. So the confidentiality boundary must be **uid +
namespace**.

Each integration runs in its own sandboxed **`--user` systemd service**
in a distinct user namespace (`PrivateUsers=managed` → a transient host
uid from `systemd-nsresourced`, plus the kernel/namespace hardening
set from `sandbox.ts`), generated from a **manifest** the user
approves when enabling it.

The wall is anchored by the namespace-owner rule (`user_namespaces(7)`):
**a namespace is owned by the uid that created it, and the owner holds
all capabilities inside it.** The user's `systemctl --user` manager
(uid 1000) creates the namespaces, so uid 1000 owns — and may inspect —
all of them; that is accepted (the human owns their machine). The
agent's *entire model-controlled runtime* therefore also runs as a
`--user` `managed`-userns service, a **sibling** of the integration
namespaces. Siblings can't reach into each other (neither resides in the
other's parent; host uids differ), so the agent cannot ptrace an
integration or read its secrets. **No code the model can steer ever runs
bare as uid 1000** — that is the invariant requirement 1 rests on.

Trust roles: **trusted** — the human (uid 1000), the gateway, the
broker; **untrusted** — the agent namespace; **mutually walled peers** —
the integrations.

The agent never talks to an integration directly, and its own pi runtime
is sandboxed (the per-session `--user` `managed`-userns service above —
model loop, tools, and extensions all inside it). What stays at uid 1000
is a thin trusted **supervisor** (what `pi-sessiond` becomes), hosting the
**gateway**: it exposes each integration's tools to the model as ordinary
typed tools — invoked over pi's rpc pipe, the model never holding a
socket — speaks **MCP over unix sockets** to the sandboxed servers
(third-party servers run unmodified, wrapped), enforces per-call approvals
through the panel, and exchanges files via per-pair **shared directories**
(idmapped — the two sides have distinct host uids). See
[pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md).

Secrets are provisioned **only through the GUI** (panel form or
broker-side OAuth) and never need root: the panel/broker encrypts each as
`systemd-creds` ciphertext — **TPM2-sealed and enforced**
(`--with-key=tpm2`, never `auto`) and **user-scoped**
(`systemd-creds encrypt --user --uid=<user>`, binding
uid+username+machine-id) — into the user's own credstore. At unit start
`LoadCredentialEncrypted=` is decrypted through the privileged
`systemd-creds.socket` Varlink broker (no `tss` membership or host key
needed) into the unit's private credentials mount only. User-scope
binding makes cross-user isolation intrinsic, so no central root broker
is required.

Enabling is **rootless and rebuild-free** (req 10): a home-manager module
writes the `--user` units, the user provisions secrets into their own
credstore, and `systemctl --user enable --now` starts them. The only root
action is a one-time platform prerequisite — `systemd-nsresourced` +
`kernel.unprivileged_userns_clone=1` — without which integrations still
run but lose their distinct host uid, collapsing the wall (§7).
The agent may *propose* an enable but never performs it — the user
accepts in the panel (req 11) and the integration then persists across
sessions.

This document records the option space and why the chosen shape won, so
the decision is durable.

---

## 1. Why skills/CLIs fail

Today, integrations are *skills*: markdown instructions plus CLI tools
the agent runs through its own `bash`. Secrets live in `skill-config`'s
`secrets.toml` (mode 0600, the agent's own uid), with the CLI allowlisted
in bash-confirm. Requirement 1 is violated *by construction*: the agent
runs `skill-config get email.default.password` and the secret is in
context — and even without the allowlist, the file is readable by the
uid the agent's bash runs as.

The deeper problem is the execution domain:

> **Anything executing inside the agent's execution domain is
> agent-controlled.** Same uid + reachable filesystem means the agent
> can read the files, `LD_PRELOAD`, `ptrace`, or read `/proc/<pid>/mem`
> of any helper process. A CLI that "doesn't print the secret" is no
> protection at all.

Corollaries that drive the design:

- The confidentiality boundary is **uid + namespace**, not file modes,
  CLI behaviour, or protocol choice. Integrations must run in a
  different security context than the agent's tools.
- **A namespace is owned by the uid that created it, and the owner holds
  all capabilities inside it** (`user_namespaces(7)`). *Where the wall is
  anchored is decided by who launches the unit.* The user's manager
  launches everything, so the anchor is uid 1000: the human can inspect
  their own integrations (accepted), but the agent — confined to a
  *sibling* namespace, never running bare as uid 1000 — cannot.
- **"Never bare as uid 1000" covers the *whole* pi runtime, not just
  `bash`.** Model-steerable code includes pi extensions (arbitrary
  in-process modules) and the in-process file tools — so the entire
  runtime (loop, tools, extensions) runs in the per-session sandbox,
  driven by a thin uid-1000 supervisor that runs no model code. This is
  the runtime-isolation refactor and is a prerequisite —
  [pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md).
- The wire protocol (MCP vs. custom RPC vs. D-Bus) is a **transport
  detail**, evaluated separately from the isolation mechanism.

One pre-existing leak path to close regardless: the agent sandbox must
not see the session D-Bus or the gnome-keyring socket (`niri.nix` runs
gnome-keyring as the Secret Service backend; any same-uid process can
query it over the session bus). The `managed`-userns agent already can't
— different ns + host uid — but keep it explicit.

---

## 2. Axis 1 — isolation mechanism

| Mechanism | Boundary | Verdict |
|---|---|---|
| **`--user` unit, `PrivateUsers=managed` + hardening** | per-unit host uid (delegated by `nsresourced`) + ns; namespace owned by the uid-1000 manager | **Default tier.** Declarative from Nix; same hardening set as the `pi-sessiond` bash sandbox (`sandbox.ts`); user-scoped `LoadCredentialEncrypted=`, `IPAddressAllow/Deny=`, `BindPaths=`, `RestrictAddressFamilies=`. Needs `nsresourced` + `kernel.unprivileged_userns_clone=1`. |
| bubblewrap per call | ns only; same uid unless userns-mapped | Subsumed by `managed` userns (same idea, declarative, with cgroup limits). Skip. |
| OCI container (podman quadlet) | uid + ns + image | **Packaging tier**: third-party MCP servers often ship as containers; quadlet makes them systemd units, so the same manifest pipeline applies. |
| microVM (microvm.nix / firecracker) | kernel boundary | **Escape-hatch tier** for genuinely untrusted code. RAM per VM, no Wayland/GPU, files via virtiofs — not the default (desktop integrations impossible inside it). |
| WASM/WASI components | capability-true | Ecosystem mismatch (integrations are Python/Node CLIs). Rejected for now. |

Two execution shapes, both needed:

- **Resident unit** — stateful integrations: IMAP IDLE, the recall
  tracker, a live browser session.
- **Transient per-call unit** (`systemd-run`, like the bash sandbox) —
  stateless integrations. Also makes req 8 (temporary grants) trivial: a
  grant is a `BindPaths=` or credential on that one unit and dies with
  it.

---

## 3. Axis 2 — communication channel

**A. Status quo++ (CLIs fetch secrets from a broker).** Dead on arrival:
the CLI runs in the agent's execution domain, so the agent extracts the
secret (puppet/ptrace/preload it). Rejected.

**B. Direct MCP — pi as MCP client.** Each integration an MCP server in
its own hardened unit; the agent connects over a socket. Max ecosystem
reuse, but: stdio-MCP must be banned (a spawned server inherits the
agent's context); policy enforcement smears across pi extensions; MCP
has no real file semantics (results base64'd into context — kills the
"agent edits a cloned repo" case); unclear the pi SDK ships an MCP
client. Partial fit.

**C. Native tool calls — bespoke RPC per integration.** Tightest UX
(typed schemas, reuse the existing approval machinery) but every
integration needs bespoke glue and there's zero third-party ecosystem —
reinvents MCP, worse. Partial fit.

**D. Integration gateway — mediated MCP (B + C hybrid) ← chosen.**
`pi-sessiond` hosts one **gateway**:

- **Agent side:** integrations surface as typed tools (`defineTool`,
  schemas from the manifest). The agent never holds a socket to any
  integration.
- **Integration side:** the gateway speaks **MCP over unix socket** to
  the per-integration sandboxed servers. First-party servers are trivial
  MCP servers; mcpmarket servers run unmodified behind a wrapper unit.
- The gateway is the single **policy enforcement point**: enforces the
  manifest (tool visibility, approval flags); fires approval prompts
  through the panel; manages **per-pair shared directories** for file
  exchange (bind-mounted, idmapped, into both sandboxes); screens
  integration *output* for known secret plaintexts before it reaches
  context (defence in depth against a leaky integration).

Cost: one extra hop and gateway code we own. Worth it: MCP becomes an
implementation detail, the ecosystem is preserved, policy is
centralized.

**E. Portal-style D-Bus services.** The xdg-desktop-portal *pattern*
(sandboxed requester → portal → consent → privileged op) is right, but
the session bus has no ACLs between same-uid peers; making it safe needs
per-integration uids anyway, collapsing into D with D-Bus as transport.
Keep the pattern, skip the bus.

**F. Patterns worth recording.**

- **Outbound credential-injection proxy:** a per-integration HTTPS proxy
  injects the `Authorization` header on the way out; the integration
  never holds the token. Hardening tier for API-key/HTTP integrations,
  and gives per-*host* network control that systemd `IPAddressAllow=`
  (IP-only) cannot.
- **Broker-side OAuth:** device/auth-code flows run in the broker +
  panel; the token never transits the agent or the setup conversation
  (req 9).
- **Quarantined/Dual-LLM (CaMeL):** prompt-injection containment — a
  sub-agent reads untrusted content and returns structured data.
  Orthogonal to isolation; noted, not built now.

---

## 4. Requirements scoring

| Req | A status quo | B direct MCP | C native | **D gateway** | E portals | microVM tier |
|---|---|---|---|---|---|---|
| 1 no secrets in context | ✗ | ✓ | ✓ | ✓ (+ output screen) | ✓ | ✓ |
| 2 mutual isolation | ✗ | ✓ | ✓ | ✓ | ~ | ✓✓ |
| 3 per-secret grant | ✗ | needs broker | needs broker | broker built in | ✓ | needs broker |
| 4 per-call approval | bash-confirm only | extension hack | ✓ | ✓ centralized | ✓ | n/a |
| 5 least privilege | ✗ | ✓ via Nix | ✓ via Nix | ✓ via Nix | ✓ | ✓✓ |
| 6 manifest-driven | ✗ | out-of-band | ad hoc | ✓ unit + tools + policy | ✓ | ✓ |
| 7 text + files | files ✓ (= the bug) | text ✓ files ✗ | both, bespoke | both, by design | fd-passing ✓ | virtiofs ~ |
| 8 temp grants | ✗ | ✗ | possible | ✓ transient units / leases | ✓ | hard |
| 9 GUI-only config | partial | ✗ | possible | ✓ broker + panel own config | ✓ | needs broker |
| 3rd-party ecosystem | skills only | ✓✓ | ✗ | ✓ (wrapped) | ✗ | ✓ |

---

## 5. Chosen architecture (layered)

### 5.0 Runtime topology & sessions

`pi-sessiond` splits into a thin **supervisor** and the sandboxed pi
runtime (the runtime-isolation refactor, a prerequisite —
[pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md)):

- **Supervisor (uid 1000, trusted):** WebSocket transport, session
  lifecycle, the gateway (§5.3), broker/panel side-channels. Runs no
  model-controlled code and loads no extensions.
- **Per-session pi runtime (sandbox):** the whole `AgentSession` — model
  loop, tools, `bash`, file tools, and extensions — runs as a `--user`
  `managed`-userns service (distinct host uid), one per chat, driven by
  the supervisor over pi's headless rpc protocol. Its only outward
  channel is that pipe.
- **Integrations:** `--user` `managed`-userns units, **user-scoped**
  (shared across that user's chats), reached only by the supervisor's
  gateway.

So multiple chats are mutually-walled sibling sandboxes that share the
trusted supervisor (one process, logically separated per session) and the
user's enabled integration set. Per-call approvals are per call; grants
may be session- or user-scoped (§5.3).

### 5.1 Sandbox layer

Manifest → **home-manager-generated `--user` systemd unit** (written to
`~/.config/systemd/user/`, enabled rootless via `systemctl --user enable
--now` — req 10): `PrivateUsers=managed`
(a distinct transient host uid via `systemd-nsresourced`), the hardening
set from `sandbox.ts`, user-scoped `LoadCredentialEncrypted=` (§5.2)
for granted secrets, `IPAddressAllow=` (or an outbound proxy, §3F),
`BindPaths=` for declared paths and the per-pair shared dir (idmapped —
distinct host uids on the two sides). Persistent state in a per-user
`StateDirectory`. Resident or transient per the manifest. The **only
system-level prerequisite** (set once by root, §7) is `nsresourced`
enabled + `kernel.unprivileged_userns_clone=1`; everything else is
user-owned. An
`untrusted` trust tier swaps the unit body for a quadlet container or a
microVM; the manifest pipeline is unchanged. The agent's own pi runtime
runs under the same `managed`-userns recipe (the per-session sandbox of
§5.0) — that is what walls the agent off from integrations (§1); `bash`
and the file tools run inside it, not as separate per-command sandboxes.

### 5.2 Secret store (no root required)

A **per-user broker** (evolves `skill-config-daemon`; runs as the user,
or its job folds into the panel). Because credentials are user-scoped and
TPM2-sealed (below), nothing here needs root — cross-user isolation is
intrinsic to the encryption, not enforced by a privileged daemon.
Responsibilities:

- **Storage:** secrets at rest via `systemd-creds`, encrypted
  **user-scoped** (`systemd-creds encrypt --user --uid=<user>`, binding
  uid + username + machine-id) and **TPM2-sealed and enforced**: always
  `--with-key=tpm2`, never `auto` (which silently falls back to the host
  key). Without a usable TPM2, storing a secret *fails* — by design. A
  TPM2-class blob is undecryptable without that TPM, so the decrypt side
  enforces itself; clearing/replacing the TPM loses the secrets, and
  recovery is re-entry through the GUI (the only provisioning path
  anyway, req 9). Never in the Nix store, never in agent-reachable paths.
  (`debug/tpm-credential-poc.sh` demonstrates the full path on real
  hardware.)
- **Provisioning — GUI only (req 9):** *direct entry* — the panel renders
  a form from the manifest (field names, types, `secret: true`) and
  submits to the broker; *broker-side OAuth* — the broker runs the flow,
  the panel shows the consent UI, the token lands in the broker without
  ever existing in a conversation or file. No clan-vars / sops / file
  path. (Machine-level secrets like the executor `hello` token are out of
  scope and keep their existing plumbing.)
- **Grants:** a table of (integration × secret) permissions. First access
  triggers a panel prompt (allow once / whitelist — req 3); decisions
  persist broker-side, never on agent-writable storage.
- **Delivery:** the broker writes the user-scoped ciphertext to a
  user-readable credstore path; the integration's `--user` unit names it
  with `LoadCredentialEncrypted=`. Decryption happens at unit start
  through the privileged **`systemd-creds.socket`** Varlink broker (root),
  so the non-root user manager needs neither the root host key nor `tss`
  TPM access; plaintext lands only in the unit's private credentials
  mount. The agent never holds the broker socket; the broker
  authenticates peers via `SO_PEERCRED`. (Units with `PrivateDevices=` /
  `DeviceAllow=` route decryption through this same broker, so the
  hardening set + `LoadCredentialEncrypted=` + TPM2 compose.)

The `skill-config` CLI and its bash-confirm allowlist entry are removed.

### 5.3 Gateway (in the supervisor)

As §3D, and living in the trusted uid-1000 supervisor (§5.0), not in the
sandboxed runtime: integrations appear to the model as typed tools — thin
stubs in the sandbox that forward the call over pi's rpc pipe; the gateway
checks the manifest/approval, speaks **MCP** over the unix socket to the
sandboxed server, screens output, and returns the result. The sandbox
never holds an integration socket. Per-call approval requests cross the
rpc pipe to the panel; unattended ones follow the remote-pi "block +
notify" parking semantics. Because enforcement lives across the namespace
boundary, a self-loaded extension cannot bypass it.

Per-call approval (the "read free, send gated" pattern — email, Signal):

- Enabling the integration is the standing grant for its non-approval
  tools: the agent reads messages with no prompts.
- An approval-flagged call **binds to its concrete arguments**: the
  prompt shows them (recipient, body) and the gateway forwards exactly
  the approved args — no swap after approval. This is the load-bearing
  defence for the asymmetry: reads are automatic, so injected content (a
  hostile email) enters context unimpeded; the user seeing recipient +
  content on the effect prompt is the barrier.
- Because the gateway sees typed arguments, grants can be scoped finer
  than allow-once/always ("auto-approve sends to this recipient",
  "…this thread this session" — the req-8 shape). Decisions persist
  broker-side.
- Enforcement is structural: the flag lives outside the agent's execution
  domain and the gateway will not forward an unapproved effect call —
  unlike a system-prompt rule, the model cannot ignore it.

### 5.4 Manifest

One manifest per integration declares: tools (name, schema,
`requiresApproval`, read vs. effect); named secrets and config fields
(rendered by the panel); network access (allowed hosts); filesystem
paths; bus/Wayland interfaces (desktop integrations); trust tier
(first-party unit / container / microVM); execution shape (resident /
transient).

The user approves the manifest when enabling the integration (req 6).
First-party manifests live in this repo as Nix; imported third-party
servers get a JSON manifest checked at enable time. All approval state
lives broker-side.

### 5.5 Foreign setup & authentication flows

Some integrations are provisioned not by "panel form → broker stores a
value" but by **state owned by a vendor tool**:

- `signal-cli link`: device linking emits a `sgnl://linkdevice?…` URI to
  render as a QR and scan; the result is long-term identity key material
  signal-cli writes into its own data directory.
- Proton Mail Bridge: a resident vendor daemon with its own login
  (password + 2FA), an encrypted vault, and a bridge-generated password
  for the localhost IMAP/SMTP endpoint it exposes.

The boundary holds, it shifts: this state is **integration-owned**, lives
in the integration's `StateDirectory` under the integration's uid, and
never transits the panel, broker, or agent. The broker's role narrows to
gating *whether* the integration runs; the panel hosts the interactive
flow:

- **Setup mode.** The manifest may declare a setup flow. The user's own
  `systemctl --user` manager launches the integration unit in setup mode
  from the GUI — same unit identity, sandbox, and `StateDirectory`.
  Whatever the vendor tool writes lands in integration-owned state.
- **Interaction protocol.** Setup processes talk to the panel through a
  small generic UI protocol (evolution of the skill-config request/submit
  model): typed requests — text prompt, secret field, *show QR / render
  image*, open URL, confirm, progress — rendered by the panel.
  `signal-cli link` → setup emits a `qr` event with the URI → panel
  renders it → done when signal-cli reports linked. Proton → secret
  (password) → secret (2FA) → done. Replies stream to the integration
  without entering any conversation.
- **Resident vendor daemons** (Proton Bridge) run *inside* the
  integration's unit as companion processes; the bridge password is read
  by the integration's mail client within the same sandbox and never
  leaves.
- **Keyring expectations.** Vendor tools that demand a Secret Service get
  a **sandbox-local** shim backed by the integration's `StateDirectory` /
  per-unit credentials — never the user's session keyring (which the
  sandbox can't see anyway, §1).
- **Re-authentication.** Expiry/unlink reuses the same channel: the
  integration reports "needs attention", a notification fires (block +
  notify), the panel reopens the flow. The agent's only visibility is a
  tool error ("integration not configured"); it may suggest opening
  settings but never participates.

Setup is strictly a user ↔ integration interaction mediated by the panel.

### 5.6 Enabling integrations (agent-proposed, user-gated)

Enabling grants a whole new capability — a sandbox, tools, and usually
access to a secret — so it is the highest-stakes effect and sits **fully
outside the agent's execution domain**, by the same structural rule as
per-call approvals (§5.3): the agent proposes, a trusted component
commits, enforcement is not behavioural.

- **Propose.** A built-in `propose_integration` tool lets the agent name
  an integration to enable — a catalog id for a known/first-party one, or
  a manifest source for a third-party server. The gateway parks it and
  raises it to the panel (block + notify, §5.3). This is the agent's only
  power here: it can ask, and observe the outcome
  (`enabled` / `declined` / `needs-secrets`).
- **Review & accept.** The panel renders the **full manifest** — tools,
  per-call approval flags, network hosts, filesystem paths, and the
  secrets it will demand — for the user to scrutinise. The manifest
  display is the barrier: a hostile agent could propose a hostile
  integration, so *accepting* is the trust decision (cf. the args-bound
  approval prompt). Accept is the req-6 manifest approval.
- **Materialise.** On accept, a **trusted user-level materialiser**
  (panel/broker — never the agent) writes the `--user` unit, records the
  manifest approval in `enabled.json`, and, if the manifest declares
  secrets, runs the normal GUI provisioning flow (req 9). The agent never
  writes a unit, approves a manifest, or sees a secret.
- **Persist.** The unit and approval survive the session; the gateway
  surfaces the new tools on its next tool-list. Disable/remove is the
  same gate in reverse, panel-only.

The architecture fixes only the *gate*, not the *backend*: how a
user-accepted enable turns into a running `--user` unit at runtime — with
**no rebuild** (req 10) — is an implementation choice (§8). Whatever the
mechanism, it must be (a) runtime, (b) user-level, and (c) triggered only
by a user accept, never by the agent.

---

## 6. Use cases, checked against the shape

| Use case | Shape |
|---|---|
| Email → research → reply | Resident IMAP/SMTP unit; creds via broker; `send` is `requiresApproval` |
| Proton mail account | As email, plus Proton Bridge as a companion process inside the unit (§5.5); vault + bridge password never leave |
| Chat → calendar → invite | Same pattern, CalDAV; `invite` approval-gated |
| Signal messages | Resident unit around signal-cli; linking via the §5.5 QR channel; identity keys stay in `StateDirectory`; `send` gated |
| Modify my system | High-trust integration wrapping `nixos-rebuild`; per-call approval; polkit for privilege |
| Ask about a window | niri-screencopy integration; per-call approval (or whitelist); screenshot lands in the shared dir, agent `read`s it |
| Control browser | Integration owns the browser profile — **cookies are secrets**; agent gets observe/act tools only, never the profile dir |
| Recall | Resident tracker; integration-owned encrypted store; query-only tool; the DB never enters context |
| Wikidata questions | No secrets; network-only sandbox; trivial integration |
| Fix a GitHub project | Integration holds the PAT, clones into the shared dir; the agent edits the tree with its normal tools; integration pushes + opens the PR behind approval |

The GitHub case justifies shared-dir file exchange over MCP-embedded file
payloads: the agent needs its full native editing toolchain on the tree.

---

## 7. Multi-user

Each user's own `systemctl --user` manager runs that user's agent and
integrations — the whole multi-user story. No eval-time user list, no
per-user codegen, no privileged "start units for users" hop:

- One static **`--user` unit per integration** ships in the user systemd
  path; the user's own manager starts it (socket-activated). Imperatively
  added users (`users.mutableUsers = true`, KDE settings, `useradd`) work
  unchanged — a new user simply has their own manager.
- **uid isolation comes from `PrivateUsers=managed`.** `nsresourced`
  delegates a transient 65536-uid range to the unit's user namespace, so
  the integration runs as a distinct *host* uid even under an
  unprivileged manager. `self`/`identity` do **not** suffice — they keep
  host uid 1000, leaving DAC, signals, the keyring and same-uid ptrace
  open. `managed` is load-bearing.
- **The wall is anchored at uid 1000** (the namespace-owner rule, §1). The
  user's manager creates the namespaces, so uid 1000 owns — and can
  inspect — all of them. Mutual isolation between agent and integrations
  (and between integrations) holds because each is a *sibling* `managed`
  userns: no sibling resides in another's parent, and host uids differ.
  Only a bare-uid-1000 process (the human, gateway, broker) can reach in.
- Persistent state in a per-user `StateDirectory`, chowned to the
  delegated uid at each start. Nothing outside
  `StateDirectory`/`CacheDirectory` may be owned by an integration
  (delegated uids are ephemeral).
- **Enabling needs neither root nor a rebuild (req 10).** The `--user`
  units, sockets, and the integration packages are produced by a
  *home-manager* module into `~/.config/systemd/user/`; the user enables
  them with `systemctl --user enable --now` and provisions secrets into
  their own credstore. The single system-level action — set once by root
  when the platform is installed, never per integration — is enabling
  `systemd-nsresourced` + `kernel.unprivileged_userns_clone=1`. Without it
  integrations still *run*, but only with `self`/`identity` userns (host
  uid 1000), so the agent↔integration wall collapses (§1): the
  prerequisite buys *isolation*, not *function*.

The broker (§5.2) runs as the user; user-scoped `systemd-creds` ciphertext
(decrypted via the root `systemd-creds.socket` helper) ensures a user can
only ever decrypt their own secrets, so no central root daemon is needed
to partition secrets between users. GUI-only provisioning (req 9) is
unchanged.

---

## 8. Open questions

- Does the pi SDK ship an MCP client? Architecture-irrelevant (the
  gateway owns the MCP side either way) but determines code size. Verify
  against `@mariozechner/pi-coding-agent`.
- Per-host network filtering: systemd filtering is IP-only. Per-integration
  proxy from day one, or accept IP granularity in v1?
- Remote executors: one broker + gateway per executor matches the "one
  user per Harness" model; secrets entered through the GUI per executor,
  no machine-provisioning channel for integration secrets.
- **Unprivileged-userns kernel surface is in the agent's TCB.** The agent
  runs inside a `managed` userns it partly controls; a userns kernel LPE →
  root → defeats the scheme. Mitigate with `RestrictNamespaces=` (forbid
  further nested unshares) + the seccomp filters; accepted residual.
- **Shared rw dirs across two distinct-host-uid namespaces** (file
  exchange, §5.3/§6) need **idmapped bind mounts** or a common gid — two
  `managed` ranges share no uid. `nsresourced` supports idmapped mounts.
- Output screening catches verbatim leaks, not encodings (base64 of a
  token). Defence in depth, not a guarantee — the real guarantee is the
  uid/namespace boundary.
- **Verify encrypt-as-user on systemd 260:** `systemd-creds encrypt --user
  --uid=self --with-key=tpm2` must succeed for a non-root user via
  `systemd-creds.socket` (a ~v256 "Selected key not available in --uid=
  scoped mode, refusing" bug existed). If it regressed, users need `tss`
  group membership — a one-time root touch, still not per-integration.
- **Enablement backend (agent-proposed enable, §5.6):** how a
  user-accepted enable materialises a `--user` unit at runtime without a
  rebuild — regenerate + re-activate the home-manager config, a small
  user-level templating daemon, or a vetted manifest registry the catalog
  ids resolve against. The gate is fixed (agent proposes, user accepts,
  trusted user-level materialiser writes the unit); the mechanism is open.
- **Runtime isolation is a prerequisite, not part of this design.** The
  agent's pi runtime (loop, tools, extensions) must run sandboxed before
  integrations ship; otherwise pi extensions and the in-process file tools
  run bare as uid 1000 and void req 1. Tracked in
  [pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md);
  it lands first.

---

## 9. Minimal POC plan

One real integration, end to end, every critical mechanism exercised
once. Pick: **GitHub** (PAT secret, one read tool, one approval-gated
effect tool, one file-exchange tool). Requires systemd ≥258 (the distro
ships 260), `systemd-nsresourced`, and `kernel.unprivileged_userns_clone=1`.
Assumes the runtime-isolation refactor has landed (sandboxed pi runtime +
supervisor gateway — [pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md)).

### 9.1 Components

1. **home-manager module** `modules/home-manager/spaces-integrations.nix`
   (new): takes manifests as Nix attrsets and writes, per integration,
   into `~/.config/systemd/user/` a **`--user` service**
   `spaces-integration-<name>.service` — `PrivateUsers=managed`,
   `StateDirectory=spaces-integrations/<name>`, the `sandbox.ts` hardening
   set, `LoadCredentialEncrypted=<sec>:<user-credstore-path>` per
   declared secret, a coarse network toggle (`IPAddressDeny=any` vs.
   allow) — plus a **`--user` socket** `spaces-integration-<name>.socket`
   (`ListenStream=%t/spaces-integrations/<name>.sock`, `SocketMode=0600`).
   Enabling is `systemctl --user enable --now`; no rebuild (req 10).
   Socket activation: the gateway connects, the user manager starts the
   instance. A separate tiny **NixOS module** does the one-time platform
   setup (`systemd-nsresourced` + the userns sysctl) — the only root part.

   ```nix
   services.spaces-integrations.integrations.github = {
     command = "${integration-github}/bin/integration-github";
     shape = "resident";
     secrets.token.description = "GitHub personal access token";
     network = true;
     tools.get_repo.approval = false;
     tools.create_issue.approval = true;
   };
   ```

2. **Broker** `packages/spaces-integrationd/` (Go, small static daemon —
   runs as the **user**, not root): a per-user socket. Ops `list`,
   `enable`, `set-secret`, `status`. `set-secret` pipes the value through
   `systemd-creds encrypt --user --uid=self --name=<sec> --with-key=tpm2`
   into the user's credstore and discards the plaintext (TPM2 enforced —
   storing fails without a usable TPM2). `enable` records the manifest
   approval (req 6) and writes a per-user `enabled.json` (metadata only,
   no secrets) the gateway consumes. No root daemon and no central secret
   store — user-scope binding keeps users' secrets mutually undecryptable.

3. **Demo integration** `packages/integration-github/` (Python, stdlib —
   `socket.socket(fileno=3)` makes socket activation trivial): minimal MCP
   server (`initialize`, `tools/list`, `tools/call`) on the activated
   socket fd. Reads the PAT from `$CREDENTIALS_DIRECTORY/token`. Tools:
   `get_repo` (read), `create_issue` (effect, approval-gated),
   `clone_to_workspace` (clones into the shared dir; stretch).

4. **Gateway in the supervisor:** read `enabled.json`; expose one
   forwarding stub per manifest tool to the sandboxed pi runtime (over the
   rpc pipe); on call, check the approval flag (panel prompt, block +
   notify when unattended), then MCP `tools/call` over the user socket.
   The shared dir is idmapped into both the session sandbox and the
   integration unit. (Depends on the runtime-isolation refactor.)

5. **Panel (minimal, req 9):** reuse the skill-config request/submit
   machinery — an enable action plus a secret-entry prompt rendered from
   the manifest fields, submitting to the broker. No settings-page polish.

### 9.2 Secret path (the part the POC must prove)

```
panel form ──user socket──▶ broker ──systemd-creds encrypt --user --uid──▶
    user-scoped, TPM2-sealed ciphertext in the user's credstore
unit start: user manager ──▶ systemd-creds.socket (root) decrypts ──▶
    private ramfs credentials mount, instance-only
agent: no path — sibling managed userns, different host uid, cannot
    ptrace or read the integration. Only bare uid 1000 (human) can.
```

### 9.3 Checks (repo testing conventions)

- `checks/spaces-integrations-nix-eval`: manifest → unit codegen asserts
  (pattern: `spaces-noctalia-nix-eval`).
- Broker protocol unit tests inside the Go package.
- `checks/pi-sessiond-integration-gateway`: cheap headless check — the
  real daemon against a stub MCP socket and a scripted mock LLM. Asserts:
  tools registered and forwarded; approval-flagged call opens the confirm
  side channel with the args in the prompt; deny returns "Denied by user."
  and the stub never sees the call; daemon without the integrations env
  exposes no integration tools.
- `checks/integration-poc-machine`: **new** VM test (not bolted onto
  `test-machine.nix`): `virtualisation.tpm.enable = true` (swtpm),
  `nsresourced` enabled, users alice and bob, GitHub API replaced by a
  local mock HTTP server. Asserts:
  - enable is refused while secrets are missing;
  - at rest only ciphertext (plaintext grep finds nothing);
  - the instance sees the plaintext (a `secret_fingerprint` debug tool
    returns its sha256 prefix);
  - other users cannot decrypt (user-scoped creds);
  - the integration authenticates against the mock API with the delivered
    token (Authorization header observed server-side);
  - alice's and bob's instances run as different delegated host uids;
    bob can neither read alice's `StateDirectory` nor connect to her
    socket;
  - the agent namespace cannot ptrace or read an integration namespace,
    while bare uid 1000 can.
  - a normal user (no root, no rebuild) can enable, provision, and launch
    an integration end to end;
  - `systemd-creds encrypt --user --with-key=tpm2` succeeds as that
    non-root user (encrypt-as-user, §8).

### 9.4 Order of work

1. Nix codegen + eval check (red-green on the unit text).
2. Broker + protocol tests.
3. Demo integration + socket activation; drive it with `socat` before pi.
4. Gateway + cheap pi-session check.
5. Panel prompts + approval flow.
6. Full VM check with TPM, `nsresourced`, and both users.

### 9.5 Explicit non-goals

Container/microVM tiers, per-host network proxy, OAuth, the §5.5
foreign-setup channel (QR), third-party server wrapping, output screening
(stretch), instance lifecycle on logout, multi-executor, agent-proposed
enable (§5.6). Removing the
legacy `skill-config` path happens after the POC proves out, not during.
