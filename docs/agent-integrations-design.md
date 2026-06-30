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
    (via a user-level materialiser, home-manager or otherwise) — no `nixos-rebuild switch`, no per-integration
    root action.
11. **Agent-proposed, user-gated enablement.** The agent may *propose*
    enabling an integration; it can never enable one itself. The user
    accepts in the panel (this is the req-6 manifest approval), after
    which the integration is permanently available across sessions.

**Prerequisite — runtime isolation (shipped).** This design assumes the
pi runtime itself runs sandboxed: the model loop, every tool, `bash`, the
file tools, and any extension run confined, driven by a thin trusted
supervisor (`pi-sessiond`) that runs no model-steerable code. That
confinement is a self-applied **Landlock** domain — *not* a user
namespace — built by `pi-landlock-exec` between `systemd-run --user` and
`pi`. It is built and shipped:
[landlock-sandbox-design.md](./landlock-sandbox-design.md) (the
mechanism) and [pi-runtime-isolation-refactor.md](./pi-runtime-isolation-refactor.md)
(the supervisor/RPC inversion). Without it, model-steerable code —
notably pi extensions and the in-process file tools — would run bare and
own every integration it could reach, voiding req 1.

## TL;DR

Anything the agent's execution domain can reach is agent-controlled: it
can read those files, `connect()` those sockets, and — for any process
in the *same* Landlock domain — `LD_PRELOAD`/`ptrace`/read
`/proc/<pid>/mem`. A CLI that "doesn't print the secret" is no
protection. So the confidentiality boundary is the **Landlock domain**:
what a domain does not grant, the code inside it cannot reach.

Each integration runs in its own **`--user` systemd service** confined by
its own **Landlock domain** — the same `pi-landlock-exec` launcher and
landlockconfig policy format that confine the agent's per-session runtime
(one mechanism, both sandboxes; [landlock §7](./landlock-sandbox-design.md)).
The policy is **lowered from a manifest** the user approves on enable.

The wall between the agent and an integration is that they are
**independent sibling Landlock domains**. A domain may `ptrace` (or read
`/proc/<pid>/mem`) only a process in the *same or a descendant* domain
(`hook_ptrace_access_check`, present since Landlock ABI 1, unconditional);
two siblings are neither, so the agent cannot trace or read an
integration and vice-versa — even though, under an unprivileged `--user`
manager, both run as the **same uid** (req 10: no rootless path to a
distinct host uid exists without the abandoned `nsresourced`/managed-userns
machinery). Filesystem confidentiality is the same wall from the other
side: neither domain grants the other's `StateDirectory`, credential
mount, or socket. Trusted code — the human, the gateway, the broker —
runs in *no* (or a permissive) domain at the user's uid and can therefore
mediate; **no code the model can steer runs unconfined.**

Trust roles: **trusted** — the human, the gateway, the broker;
**untrusted** — the agent's Landlock domain; **mutually walled peers** —
the integrations' Landlock domains.

The agent never talks to an integration directly. What stays unconfined
is a thin trusted **supervisor** (`pi-sessiond`) hosting the **gateway**:
it exposes each integration's tools to the model as ordinary typed tools
— invoked over pi's rpc pipe, the model never holding a socket — speaks
**MCP over unix sockets** to the sandboxed servers (third-party servers
run unmodified, wrapped), enforces per-call approvals through the panel,
and exchanges files via per-pair **shared directories** (a plain dir
granted to both sides' policies — same uid, so no idmapping needed).

Secrets are provisioned **only through the GUI** (panel form or
broker-side OAuth) and never need root: the broker encrypts each as
`systemd-creds` ciphertext — **TPM2-sealed and enforced**
(`--with-key=host+tpm2`, never `auto`) and **user-scoped**
(`systemd-creds encrypt --user --uid=<user>`, binding
uid+username+machine-id) — into the user's own credstore. At unit start
`LoadCredentialEncrypted=` is decrypted through the privileged
`systemd-creds.socket` Varlink broker (no `tss` membership or host key
needed) into the unit's private credentials mount only. User-scope
binding makes cross-user isolation intrinsic, so no central root broker
is required.

Enabling is **rootless and rebuild-free** (req 10): a trusted user-level
materialiser — a declarative NixOS module emitting `systemd.user.services` (or
home-manager) for first-party integrations, the broker (a runtime materialiser)
for on-the-fly third-party ones — writes the
`--user` units and their landlockconfig policies, the user provisions
secrets into their own credstore, and `systemctl --user enable
--now` starts them. There is **no system-level prerequisite** beyond a
kernel with Landlock (ABI 6 — Linux 6.12+ — for full IPC scoping; older
kernels keep the FS and ptrace walls and degrade only the
abstract-socket/signal scopes). The agent may *propose* an enable but
never performs it — the user accepts in the panel (req 11) and the
integration then persists across sessions.

This document records the option space and why the chosen shape won, so
the decision is durable.

---

## 1. Why skills/CLIs fail

Today, integrations are *skills*: markdown instructions plus CLI tools
the agent runs through its own `bash`. Secrets live in `skill-config`'s
`secrets.toml` (mode 0600, the agent's own uid), with the CLI allowlisted
in bash-confirm. Requirement 1 is violated *by construction*: the agent
runs `skill-config get email.default.password` and the secret is in
context — and even without the allowlist, the file is readable inside the
agent's own domain.

The deeper problem is the execution domain:

> **Anything executing inside the agent's execution domain is
> agent-controlled.** Reachable filesystem + same Landlock domain means
> the agent can read the files, `LD_PRELOAD`, `ptrace`, or read
> `/proc/<pid>/mem` of any helper process. A CLI that "doesn't print the
> secret" is no protection at all.

Corollaries that drive the design:

- The confidentiality boundary is the **Landlock domain** (a
  deny-by-default FS/net/IPC allowlist), not file modes, CLI behaviour,
  or protocol choice. Integrations must run in a *different* domain than
  the agent's tools.
- **A domain may trace into only the same or a descendant domain**
  (`hook_ptrace_access_check`). *Where the wall is anchored is decided by
  who applies which domain.* The agent and each integration get their own
  sibling domain via `pi-landlock-exec`, so neither can `ptrace`/read the
  other; trusted code applies no domain and can inspect, by design.
- **The wall is independent of uid.** Under a `--user` manager every unit
  runs at the user's uid (req 10 forbids the root action a distinct uid
  would need). The Landlock ptrace rule, plus per-unit private credential
  mounts and the FS allowlist, are what separate same-uid peers. This is
  a **single enforcement layer** (no independent DAC backstop) — the
  accepted residual of staying rootless (§8).
- **"Confined" covers the *whole* pi runtime, not just `bash`.**
  Model-steerable code includes pi extensions (arbitrary in-process
  modules) and the in-process file tools — so the entire runtime (loop,
  tools, extensions) runs in the per-session Landlock domain, driven by a
  thin supervisor that runs no model code. This is the runtime-isolation
  refactor and is shipped —
  [landlock-sandbox-design.md](./landlock-sandbox-design.md).
- The wire protocol (MCP vs. custom RPC vs. D-Bus) is a **transport
  detail**, evaluated separately from the isolation mechanism.

One pre-existing leak path to close regardless: the agent sandbox must
not see the session D-Bus or the gnome-keyring socket (`niri.nix` runs
gnome-keyring as the Secret Service backend; any process that can reach
the session bus can query it). The agent's Landlock domain already
denies both — neither path is granted — but keep it explicit.

---

## 2. Axis 1 — isolation mechanism

| Mechanism | Boundary | Verdict |
|---|---|---|
| **`--user` unit + per-integration Landlock domain (`pi-landlock-exec`) + systemd hardening** | deny-by-default FS/net/IPC domain, sibling to the agent's; ptrace/mem walled by the Landlock domain rule; same uid | **Default tier.** Rootless and rebuild-free (req 10); one launcher + policy format shared with the agent runtime; user-scoped `LoadCredentialEncrypted=`, `RestrictAddressFamilies=`/proxy, network and paths from the manifest. Needs only a Landlock kernel. |
| `--user` unit, `PrivateUsers=managed` (`nsresourced`) | per-unit delegated host uid + ns | **Rejected.** Gives a distinct uid under an unprivileged manager, but the feature is still early-stage: a `--user` `managed` unit gets no *writable* host bind-mount — the idmap that would make a host dir writable is system-scope only, and `BindPaths=…:idmap` exists in `systemd-nspawn`, not service units (issue #34695) — so it cannot expose the user's own files to the runtime. Abandoned project-wide in favour of Landlock. |
| system unit, `DynamicUser=` | distinct *real* host uid + ns | **Multi-tenant / belt-and-suspenders tier.** A genuine second (DAC) layer, but `DynamicUser` is root-only (system unit) → a rebuild to add an integration and a root broker: violates req 10. Reserve for an untrusted-third-party tier or a server-side executor where root is already in play. |
| bubblewrap per call | ns only; same uid unless userns-mapped | Subsumed by the Landlock domain (declarative, inherited across exec, with cgroup limits from the unit). Skip. |
| OCI container (podman quadlet) | uid + ns + image | **Packaging tier**: third-party MCP servers often ship as containers; rootless podman quadlets keep req 10. The manifest still drives the unit. |
| microVM (microvm.nix / firecracker; **muvm/libkrun**) | kernel boundary | **Escape-hatch / untrusted tier.** Strongest boundary (own kernel), historically impractical for desktop integrations: RAM per VM, no Wayland/GPU, files only via virtiofs. A muvm/libkrun runner — **munix** (clan.lol) — closes most of that gap (GPU acceleration, Wayland, PipeWire, host `--bind`/`--expose` paths, per-VM uid/gid), making a genuinely-untrusted tier practical. Kept for a later iteration (§8); needs `/dev/kvm` + a recent kernel, so not the v1 default. |
| WASM/WASI components | capability-true | Ecosystem mismatch (integrations are Python/Node CLIs). Rejected for now. |

Two execution shapes, both needed:

- **Resident unit** — stateful integrations: IMAP IDLE, the recall
  tracker, a live browser session.
- **Transient per-call unit** (`systemd-run --user`, like the agent's own
  launcher) — stateless integrations. Also makes req 8 (temporary grants)
  trivial: a grant is a path or credential on that one unit's policy and
  dies with it.

---

## 3. Axis 2 — communication channel

**A. Status quo++ (CLIs fetch secrets from a broker).** Dead on arrival:
the CLI runs in the agent's execution domain, so the agent extracts the
secret (puppet/ptrace/preload it). Rejected.

**B. Direct MCP — pi as MCP client.** Each integration an MCP server in
its own confined unit; the agent connects over a socket. Max ecosystem
reuse, but: stdio-MCP must be banned (a spawned server inherits the
agent's domain); policy enforcement smears across pi extensions; MCP has
no real file semantics (results base64'd into context — kills the "agent
edits a cloned repo" case); unclear the pi SDK ships an MCP client.
Partial fit.

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
  exchange (a plain dir granted to both sides' Landlock policies);
  screens integration *output* for known secret plaintexts before it
  reaches context (defence in depth against a leaky integration).

Cost: one extra hop and gateway code we own. Worth it: MCP becomes an
implementation detail, the ecosystem is preserved, policy is
centralized.

**E. Portal-style D-Bus services.** The xdg-desktop-portal *pattern*
(sandboxed requester → portal → consent → privileged op) is right, but
the session bus has no ACLs between same-domain peers; making it safe
needs the gateway anyway, collapsing into D with D-Bus as transport. Keep
the pattern, skip the bus.

**F. Patterns worth recording.**

- **Outbound credential-injection proxy:** a per-integration HTTPS proxy
  injects the `Authorization` header on the way out; the integration
  never holds the token. Hardening tier for API-key/HTTP integrations,
  and gives per-*host* network control that the Landlock netPort grant
  (port-only) and systemd `IPAddressAllow=` (IP-only) cannot. This is the
  same shape the agent runtime already uses for its model key
  (`packages/pi-sessiond/proxy.ts`).
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
| 2 mutual isolation | ✗ | ✓ | ✓ | ✓ (Landlock domains) | ~ | ✓✓ |
| 3 per-secret grant | ✗ | needs broker | needs broker | broker built in | ✓ | needs broker |
| 4 per-call approval | bash-confirm only | extension hack | ✓ | ✓ centralized | ✓ | n/a |
| 5 least privilege | ✗ | ✓ via manifest | ✓ via manifest | ✓ via manifest | ✓ | ✓✓ |
| 6 manifest-driven | ✗ | out-of-band | ad hoc | ✓ unit + policy + tools | ✓ | ✓ |
| 7 text + files | files ✓ (= the bug) | text ✓ files ✗ | both, bespoke | both, by design | fd-passing ✓ | virtiofs ~ |
| 8 temp grants | ✗ | ✗ | possible | ✓ transient units / leases | ✓ | hard |
| 9 GUI-only config | partial | ✗ | possible | ✓ broker + panel own config | ✓ | needs broker |
| 10 rootless / no rebuild | ✓ (= the bug) | depends | depends | ✓ `--user` + Landlock | depends | ✗ |
| 3rd-party ecosystem | skills only | ✓✓ | ✗ | ✓ (wrapped) | ✗ | ✓ |

---

## 5. Chosen architecture (layered)

### 5.0 Runtime topology & sessions

`pi-sessiond` is a thin **supervisor** driving sandboxed pi runtimes (the
runtime-isolation refactor, shipped —
[landlock-sandbox-design.md](./landlock-sandbox-design.md)):

- **Supervisor (trusted, no Landlock domain):** WebSocket transport,
  session lifecycle, the gateway (§5.3), broker/panel side-channels. Runs
  no model-controlled code and loads no extensions.
- **Per-session pi runtime (sandbox):** the whole `AgentSession` — model
  loop, tools, `bash`, file tools, and extensions — runs under a
  per-session **Landlock domain** (`pi-landlock-exec`), one per chat,
  driven by the supervisor over pi's headless rpc protocol. Its only
  outward channel is that pipe.
- **Integrations:** `--user` **Landlock-domain** units, **user-scoped**
  (shared across that user's chats), reached only by the supervisor's
  gateway.

So multiple chats are mutually-walled sibling domains that share the
trusted supervisor (one process, logically separated per session) and the
user's enabled integration set. Per-call approvals are per call; grants
may be session- or user-scoped (§5.3).

### 5.1 Sandbox layer

Manifest → a **trusted user-level materialiser** writes a `--user` systemd unit
(a NixOS module emitting `systemd.user.services` — the declarative backend in
this repo — or home-manager for first-party; the broker as a runtime
materialiser for on-the-fly third-party, §5.6), enabled rootless via `systemctl
--user enable --now` (req 10), whose `ExecStart` runs the integration through
`pi-landlock-exec` with a **landlockconfig policy lowered from the
manifest** (§5.4, §7): a deny-by-default FS allowlist (the integration's
`StateDirectory`, its credential mount, the per-pair shared dir, and
nothing else), a netPort/`RestrictAddressFamilies` grant or an outbound
proxy (§3F), and ABI-6 IPC scoping (abstract unix sockets + signals) so
same-uid siblings cannot reach the integration's abstract sockets or
signal it. Plus the systemd hardening set (`NoNewPrivileges`,
`ProtectKernelTunables/Modules/Logs`, `ProtectControlGroups`,
`ProtectClock`, `ProtectProc=invisible`, `RestrictSUIDSGID`,
`LockPersonality`, `RestrictNamespaces`, `SystemCallFilter=`), and
user-scoped `LoadCredentialEncrypted=` (§5.2) for granted secrets.
Persistent state in a per-user `StateDirectory` (mode 0700). Resident or
transient per the manifest.

There is **no system-level prerequisite** beyond a Landlock kernel:
no `nsresourced`, no userns sysctl, no systemd rebuild.
An `untrusted` trust tier may swap the unit body for a rootless podman
quadlet or a microVM (§2); the manifest pipeline is unchanged. The
agent's own pi runtime runs under the **same** `pi-landlock-exec` recipe
(the per-session sandbox of §5.0) — that, plus a non-overlapping
allowlist, is what walls the agent off from integrations (§1); `bash` and
the file tools run inside it, not as separate per-command sandboxes.

### 5.2 Secret store (no root required)

A **per-user broker** (evolves `skill-config-daemon`; runs as the user,
or its job folds into the panel). Because credentials are user-scoped and
TPM2-sealed (below), nothing here needs root — cross-user isolation is
intrinsic to the encryption, not enforced by a privileged daemon.
Responsibilities:

- **Storage:** secrets at rest via `systemd-creds`, encrypted
  **user-scoped** (`systemd-creds encrypt --user --uid=<user>`, binding
  uid + username + machine-id) and **TPM2-sealed and enforced** via
  `--with-key=host+tpm2`, never `auto` (which silently falls back to the host
  key alone). `host+tpm2` (not pure `tpm2`) is required: user-scoping needs the
  host-key component to bind a uid, and pure `tpm2` is rejected in `--uid=` mode.
  Both components are mandatory to decrypt, so the TPM is genuinely enforced — a
  blob is undecryptable without that TPM; clearing/replacing it loses the
  secrets, and recovery is re-entry through the GUI (the only provisioning path
  anyway, req 9). Never in the Nix store, never in agent-reachable paths.
  (`debug/tpm-credential-poc.sh` demonstrates the full path on real hardware.)
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
  with `LoadCredentialEncrypted=`. The broker encrypts as the user, which needs
  TPM access — integration users are granted `tss` at onboarding (a one-time
  host action, not per-integration). Decryption happens at unit start through the
  privileged **`systemd-creds.socket`** Varlink broker (root), so the unit needs
  no TPM access of its own; plaintext lands only in the unit's private
  credentials mount — which the agent's Landlock domain does not grant. The agent
  never holds the broker socket; the broker authenticates peers via
  `SO_PEERCRED`.

The `skill-config` CLI and its bash-confirm allowlist entry are removed.

### 5.3 Gateway (in the supervisor)

As §3D, and living in the trusted supervisor (§5.0), not in the sandboxed
runtime. On connect it speaks **MCP** to each enabled integration's sandboxed
server over its unix socket — `initialize` then `tools/list` — and **registers
each discovered tool as a typed pi tool** for the model (thin stubs that forward
over pi's rpc pipe). Schemas come from the (untrusted) server: they are
*presentation only* and gate nothing — the load-bearing barrier is the
args-bound confirm below, not the schema. The sandbox never holds an integration
socket (its Landlock domain does not grant the socket path), and because
enforcement lives across the domain boundary a self-loaded extension cannot
bypass it.

The manifest carries an **`autoRun` allowlist**, not per-tool schemas:

- **Allowlisted tools run with no prompt** — the agent reads with no friction.
- **Every other discovered tool is still callable, but each call requires user
  confirmation.** An empty allowlist ⇒ a freshly-plugged (e.g. third-party)
  server is all-confirm until the user blesses tools, so an unmodified MCP server
  plugs in with zero manual schema transcription.
- The confirm prompt **binds to the call's concrete arguments**: it shows exactly
  what the gateway will forward (recipient, body, repo, …) and forwards exactly
  that — no swap after approval. This is the structural defence for the
  read/effect asymmetry: reads are automatic, so injected content (a hostile
  email) enters context unimpeded; the human seeing the real arguments on the
  effect prompt is the barrier. MCP tool annotations (`readOnlyHint`,
  `destructiveHint`) are *untrusted hints* — the panel may use them to suggest
  what to allowlist, never to decide auto-run.
- Prompt options are **Allow once · Allow for this session · Deny**. A session
  grant is an ephemeral, tool-name-scoped entry in the gateway's per-session
  state; **allow-forever and finer args-bound grants (the req-8 shape) are
  deferred**, so `enabled.json` records only which integrations are enabled, not
  tool grants. Deny returns "Denied by user." and the server never sees the call.
- Per-call prompts cross the rpc pipe to the panel; unattended ones follow the
  remote-pi "block + notify" parking semantics. Enforcement is structural — the
  allowlist + gateway live outside the agent's execution domain, so the model
  cannot bypass them.

### 5.4 Manifest

One manifest per integration declares its **sandbox and provisioning posture** —
the part a server cannot be trusted to declare about its own cage: named secrets
and config fields (rendered by the panel); network access; filesystem paths;
bus/Wayland interfaces (desktop integrations); trust tier (first-party unit /
container / microVM); execution shape (resident / transient); and the **`autoRun`
tool allowlist** (§5.3). It does **not** redeclare tool schemas — those are
discovered at runtime from the server's `tools/list` (§5.3). The filesystem,
network, and IPC posture is what the trusted materialiser **lowers to a
landlockconfig policy** (§5.1, §7); the author writes the high-level manifest,
never the policy.

The user approves the manifest when enabling the integration (req 6). First-party
manifests live in this repo as Nix; imported third-party servers get a JSON
manifest checked at enable time. All approval state lives broker-side.

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
in the integration's `StateDirectory` (granted only by the integration's
own Landlock policy) and never transits the panel, broker, or agent. The
broker's role narrows to gating *whether* the integration runs; the panel
hosts the interactive flow:

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
  (panel/broker — never the agent) writes the `--user` unit and its
  landlockconfig policy, records the manifest approval in `enabled.json`,
  and, if the manifest declares secrets, runs the normal GUI provisioning
  flow (req 9). The agent never writes a unit, lowers a policy, approves a
  manifest, or sees a secret.
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
Same uid on both sides makes the shared dir an ordinary directory granted
to both Landlock policies — no idmapping.

---

## 7. Multi-user

Each user's own `systemctl --user` manager runs that user's agent and
integrations — the whole multi-user story. No eval-time user list, no
per-user codegen, no privileged "start units for users" hop:

- One **`--user` unit per integration** in the user systemd path; the
  user's own manager starts it (socket-activated). Imperatively added
  users (`users.mutableUsers = true`, KDE settings, `useradd`) work
  unchanged — a new user simply has their own manager.
- **Within a user, the wall is the Landlock domain.** The user's agent
  and integrations all run at that user's uid; each is confined by its
  own sibling `pi-landlock-exec` domain, so neither can `ptrace`/read the
  other or open the other's files. Trusted code (the human, the gateway,
  the broker) applies no domain and can reach in. This is a single
  enforcement layer (§8 residual).
- **Between users, the wall is plain uid DAC.** Different humans are
  different uids; alice's integration units, `StateDirectory` (0700), and
  sockets are unreadable to bob by ownership, and user-scoped
  `systemd-creds` makes alice's secrets undecryptable by bob.
- Persistent state in a per-user `StateDirectory`. Nothing outside
  `StateDirectory`/`CacheDirectory` is integration-owned.
- **Enabling needs neither root nor a rebuild (req 10).** The `--user`
  units, their landlockconfig policies, sockets, and the integration
  packages are produced by a user-level materialiser (a NixOS module emitting
  `systemd.user.services` for first-party, the broker for on-the-fly third-party
  — §5.6) into the user systemd path; the user enables them with `systemctl --user
  enable --now` and provisions secrets into their own credstore. There is
  no system-level platform action: Landlock is on by default on the
  shipped kernel (ABI 6 for full IPC scoping; older kernels keep the FS +
  ptrace walls).

The broker (§5.2) runs as the user; user-scoped `systemd-creds` ciphertext
(decrypted via the root `systemd-creds.socket` helper) ensures a user can
only ever decrypt their own secrets, so no central root daemon is needed
to partition secrets between users. GUI-only provisioning (req 9) is
unchanged.

> **Server-side (multi-user).** A multi-user server is not a multi-tenant
> daemon — it runs **one `--user` `pi-sessiond` per remote user, each at
> that user's own uid**: the desktop mechanism replicated per
> linger-enabled account. Within a user the wall is the Landlock domain
> (above); between users it is plain DAC (distinct real uids), so a user
> adds integrations on the fly exactly as on the desktop, rootlessly. This
> retires the shared-`pi-session`-uid root executor —
> [pi-sessiond-per-user-refactor.md](./pi-sessiond-per-user-refactor.md).
> The `DynamicUser=` system-unit tier (§2) stays an *untrusted-integration*
> option (orthogonal to desktop/server), not the server model.

---

## 8. Open questions

- Does the pi SDK ship an MCP client? Architecture-irrelevant (the
  gateway owns the MCP side either way) but determines code size. Verify
  against `@mariozechner/pi-coding-agent`.
- Per-host network filtering: the Landlock netPort grant and systemd
  filtering are port/IP-only. Per-integration proxy (§3F) from day one,
  or accept port granularity in v1?
- **Same-uid single-layer residual (accepted).** Under req 10 the agent
  and a user's integrations share a uid; the wall is the Landlock domain
  alone, with no independent DAC backstop. A Landlock-bypass kernel bug,
  or a kernel too old for a needed scope, weakens it. Mitigations: pin a
  Landlock ABI floor; keep `RestrictNamespaces=` + the seccomp filter so
  the sandbox can't unshare its way out; offer the `DynamicUser` /
  container / microVM tiers (§2) for higher-trust needs.
- **microVM untrusted tier via muvm/libkrun (later iteration).** The §2
  microVM objections — no GPU/Wayland, awkward virtiofs file exchange,
  heavy per-VM cost — are largely answered by a desktop-integration
  microVM runner, **munix** (`git.clan.lol/clan/munix`, muvm/libkrun):
  GPU + Wayland + PipeWire passthrough, host `--bind`/`--ro-bind`/`--expose`
  paths, and a per-VM uid/gid. It is WIP and needs `/dev/kvm` + a recent
  kernel (6.13+ for GPU), so it is not the v1 mechanism — but it is the
  leading candidate for a genuinely-untrusted integration tier (mcpmarket
  servers; a kernel-boundary backstop above the same-uid Landlock wall)
  in a later iteration. Keep it in mind.
- **Landlock ABI availability.** Abstract-unix-socket and signal scoping
  need ABI 6 (Linux 6.12+). On older kernels `pi-landlock-exec` degrades
  best-effort: FS and ptrace/mem walls hold; an integration's abstract
  sockets and cross-domain signals become reachable by a same-uid sibling.
  Track the kernel floor.
- **Encrypt-as-user (resolved).** Pure `tpm2` is rejected in user-scoped mode on
  systemd 260 (`Selected key not available in --uid= scoped mode`); the secret
  path uses **`host+tpm2`** with integration users in `tss` at onboarding
  (§5.2). Verified on the target host (systemd 260, kernel 6.18).
- **Enablement backend (agent-proposed enable, §5.6):** how a
  user-accepted enable materialises a `--user` unit + policy at runtime
  without a rebuild — regenerate + re-activate the declarative materialiser (the
  NixOS module, or home-manager), a
  small user-level templating daemon, or a vetted manifest registry the
  catalog ids resolve against. The gate is fixed (agent proposes, user
  accepts, trusted user-level materialiser writes the unit); the
  mechanism is open.
- Output screening catches verbatim leaks, not encodings (base64 of a
  token). Defence in depth, not a guarantee — the real guarantee is the
  Landlock domain boundary.
- Remote executors: one `--user` `pi-sessiond` per remote user — each its
  own broker + gateway at that user's uid (the per-user refactor,
  [pi-sessiond-per-user-refactor.md](./pi-sessiond-per-user-refactor.md)),
  secrets entered through the GUI per user, no machine-provisioning
  channel for integration secrets.

---

## 9. Minimal POC plan

One real integration, end to end, every load-bearing mechanism exercised once.
Pick: **GitHub** (PAT secret; a read tool; an approval-gated effect tool; a
file-exchange tool). The execution checklist, decision log, and verified
build-gates live in
[agent-integrations-poc-plan.md](./agent-integrations-poc-plan.md); this section
is the architectural definition. Both build-gates are verified on the target
host (systemd 260, kernel 6.18): Landlock **ABI 6**, and the user-scoped secret
path via **`host+tpm2`** (pure `tpm2` is rejected in `--uid=` mode — §5.2).
Builds on the shipped sandboxed pi runtime + supervisor gateway
([landlock-sandbox-design.md](./landlock-sandbox-design.md)), reusing its
`pi-landlock-exec` launcher and `buildLandlockPolicy` emitter.

> **Note — the existing `integrations-poc` branch is superseded.** It was
> written against the abandoned managed-userns model: system `DynamicUser`
> units, a `nsresourced` platform module, a **root** broker using host-key
> `systemd-creds`, and a gateway wired into the pre-Landlock `main.ts`. It is
> **rebuilt fresh, not rebased**, onto this plan: `--user` units +
> `pi-landlock-exec`, a user-level broker with user-scoped `host+tpm2` creds,
> runtime tool discovery, and the gateway on the shipped supervisor/`rpc-driver`
> layer. Salvageable as reference: the Go broker skeleton, the Python
> `integration-github` server, and the check drivers.

### 9.1 Components

1. **Materialiser** `modules/nixos/spaces-integrations/` (new): a NixOS module
   (the repo has no home-manager) that takes manifests as Nix attrsets and
   emits, per integration, a **`--user` service**
   `systemd.user.services."spaces-integration-<name>"` and a **`--user` socket**
   `spaces-integration-<name>.socket`
   (`ListenStream=%t/spaces-integrations/<name>.sock`, `SocketMode=0600`). The
   unit's `ExecStartPre` runs a thin `spaces-landlock-policy` CLI — wrapping
   `buildLandlockPolicy` so there is one policy emitter — which resolves the
   unit-start paths (`$STATE_DIRECTORY`, `$CREDENTIALS_DIRECTORY`,
   `$RUNTIME_DIRECTORY`, shared dir) into `$RUNTIME_DIRECTORY/landlock.json`;
   `ExecStart` is then
   `pi-landlock-exec --json $RUNTIME_DIRECTORY/landlock.json -- <command>`.
   (Unit-start generation is required: a system module emits one generic user
   unit with no build-time `$HOME`, and landlockconfig variables are in-document
   templating, not env injection.) Plus
   `StateDirectory=spaces-integrations/<name>` (mode 0700), the systemd
   hardening set, and `LoadCredentialEncrypted=<sec>:<credstore-path>` per
   declared secret. The manifest→{unit, policy spec, definition JSON} lowering
   lives in a backend-agnostic `lib.nix`; `default.nix` is the thin NixOS
   adapter, so a home-manager adapter can reuse `lib.nix` later. Enabling is
   `systemctl --user enable --now` — no per-integration root, no rebuild to
   *use* (req 10).

   ```nix
   services.spaces-integrations.integrations.github = {
     command = "${integration-github}/bin/integration-github";
     shape   = "resident";
     network = true;
     secrets.token.description = "GitHub personal access token";
     autoRun = [ "get_repo" ]; # everything else => confirm-per-call
   };
   ```

2. **Broker** `packages/spaces-integrationd/` (Go, small static **`--user`**
   daemon on `%t/spaces-integrations.sock`, `SO_PEERCRED`-authed): ops `list`,
   `enable`, `set-secret`, `status`. `set-secret` pipes the value through
   `systemd-creds encrypt --user --uid=self --name=<sec> --with-key=host+tpm2`
   into the user's credstore and discards the plaintext (TPM2 enforced — storing
   fails without a usable TPM2). `enable` records the manifest approval (req 6)
   and writes a per-user `enabled.json` (which integrations are on — metadata
   only, no secrets, no tool grants). No root daemon, no central secret store:
   user-scope binding keeps users' secrets mutually undecryptable. Coexists with
   `skill-config-daemon`, which is removed *after* the POC. (Salvage the branch's
   Go; switch `credsEncrypt` to `--user --uid=self --with-key=host+tpm2` and drop
   root.)

3. **Demo integration** `packages/integration-github/` (Python, stdlib —
   `socket.socket(fileno=3)` for trivial socket activation): a minimal MCP server
   (`initialize`, `tools/list`, `tools/call`) on the activated socket fd. Reads
   the PAT from `$CREDENTIALS_DIRECTORY/token`. Tools: `get_repo` (read,
   allowlisted), `create_issue` (effect, confirm-gated), and `clone_to_workspace`
   (file exchange — step 6, §9.4). Salvage the branch's server.

4. **Gateway in the supervisor** (`packages/pi-sessiond/`): read `enabled.json`;
   for each enabled integration connect the socket, `initialize` + `tools/list`,
   and register a typed forwarding tool per discovered tool to the sandboxed pi
   runtime (over the rpc pipe). On call: if the tool is on the manifest `autoRun`
   allowlist (or session-granted) forward immediately; otherwise raise an
   args-bound confirm to the panel (Allow once / for this session / Deny; block +
   notify when unattended), then MCP `tools/call` over the user socket. For file
   exchange the per-pair shared dir is granted to both the session policy and the
   integration policy (§9.4 step 6). Rewrite onto the shipped
   supervisor/`rpc-driver`.

5. **Panel (minimal, req 9):** enable + secret entry render from the
   integration's definition JSON and submit to the broker directly; the per-call
   approval prompt rides the existing pi-sessiond executor WebSocket as an
   `approval_request` event, rendered by a confirm component modeled on
   `SignalConfirm.qml`. Reuse the skill-config request/submit *UI pattern*; no
   settings-page polish.

### 9.2 Secret path (the part the POC must prove)

```
panel form --user socket--> broker --systemd-creds encrypt --user --uid=self
    --with-key=host+tpm2--> user-scoped, TPM2-enforced ciphertext in the credstore
unit start: user manager --> systemd-creds.socket (root) decrypts -->
    private ramfs credentials mount, instance-only
agent: no path -- its Landlock domain grants neither the integration's
    credential mount nor its socket, and the domain rule blocks
    ptrace/read of the (sibling-domain) integration process. Only
    unconfined code (human, gateway, broker) can reach in.
```

Pure `tpm2` is rejected in `--user`/`--uid=` mode on systemd 260; `host+tpm2` is
the enforced-TPM path (§5.2). Integration users are in `tss` (onboarding) so the
broker can encrypt.

### 9.3 Checks (repo testing conventions)

- `checks/spaces-integrations-nix-eval`: manifest → unit + socket + policy-spec
  codegen asserts (pattern: `pi-sessiond-nix-eval`). Asserts the unit wiring
  (`ExecStartPre` policy gen, `ExecStart` `pi-landlock-exec`, `StateDirectory`,
  `LoadCredentialEncrypted`, socket `ListenStream`/`SocketMode`), and — by
  running the `spaces-landlock-policy` CLI on sample resolved paths — that the
  lowered landlockconfig is deny-by-default and grants only the declared paths /
  ports.
- Broker protocol unit tests inside the Go package (`set-secret` encrypts
  `host+tpm2` and discards plaintext; `enable` writes `enabled.json`;
  `SO_PEERCRED`).
- `checks/pi-sessiond-integration-gateway`: cheap headless check — the real
  daemon against a stub MCP socket and a scripted mock LLM. Asserts: discovered
  tools registered and forwarded; an allowlisted tool runs with no prompt; a
  non-allowlisted tool opens the confirm side channel with the args in the
  prompt; "Allow for this session" suppresses subsequent prompts for that tool
  that session; Deny returns "Denied by user." and the stub never sees the call;
  a daemon with no integrations env exposes no integration tools.
- `checks/integration-poc-machine`: **new** VM test (not bolted onto
  `test-machine.nix`): `virtualisation.tpm.enable = true` (swtpm), users alice
  and bob (both in `tss`), GitHub API replaced by a local mock HTTP server.
  Asserts:
  - enable is refused while secrets are missing;
  - at rest only ciphertext (plaintext grep finds nothing);
  - the instance sees the plaintext (a `secret_fingerprint` debug tool returns
    its sha256 prefix);
  - other users cannot decrypt (user-scoped `host+tpm2` creds);
  - the integration authenticates against the mock API with the delivered token
    (Authorization header observed server-side);
  - the **agent's Landlock domain cannot `ptrace` or read `/proc/<pid>/mem` of
    an integration process, nor open its socket / `StateDirectory` / credential
    mount, while the unconfined supervisor can** (the same-uid wall);
  - alice cannot reach bob's integration socket or `StateDirectory` (cross-user
    DAC);
  - a normal user (no root, no rebuild) can enable, provision, and launch an
    integration end to end;
  - `systemd-creds encrypt --user --uid=self --with-key=host+tpm2` succeeds as
    that non-root user;
  - **file exchange:** `clone_to_workspace` populates the shared dir, the agent
    edits the tree with its native file tools, and a push/PR effect is
    confirm-gated.

### 9.4 Order of work

One `jj` commit per step; build fresh, salvage file contents as reference.

1. **Nix codegen** — `lib.nix`/`default.nix` + the `spaces-landlock-policy` CLI +
   `spaces-integrations-nix-eval` (red-green on the unit text **and** the lowered
   policy).
2. **Broker** — `spaces-integrationd` (user-level, `host+tpm2`) + protocol tests.
3. **Demo integration** — `integration-github` (`get_repo` + `create_issue`) +
   socket activation; drive with `socat` before pi.
4. **Gateway** — runtime discovery + `autoRun`/confirm on the supervisor + cheap
   pi-session check.
5. **Panel** — enable/secret form (panel→broker) + the approval event
   (gateway→panel ws).
6. **File exchange** — per-pair shared dir granted to both the integration policy
   **and** the agent session policy; `clone_to_workspace`; agent edits natively,
   push/PR behind approval.
7. **Full VM check** — TPM (swtpm) + alice/bob: secret path, Landlock wall,
   cross-user DAC, approval, and file exchange.

### 9.5 Explicit non-goals

Container/microVM tiers, the `DynamicUser` multi-tenant tier, per-host network
proxy, OAuth, the §5.5 foreign-setup channel (QR), third-party server wrapping,
output screening (stretch), instance lifecycle on logout, multi-executor,
agent-proposed enable (§5.6), and persistent ("allow forever") / args-bound tool
grants (only ephemeral session grants ship). Removing the legacy `skill-config`
path happens after the POC proves out, not during.
