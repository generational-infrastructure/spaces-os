# Skill → integration migration: mail, caldav, contacts

**Status:** IMPLEMENTED (2026-07-01). The three secret-bearing skills (`email`,
`calendar`, `contacts`) now run as sandboxed MCP integrations on the unified,
host+tpm2-sealed profile store; `skill-config` is relocated behind the wall as
the store engine (still used unchanged by the agent-facing `google`/`signal`
skills). Built on Option 3 (blob-credential store; TPM-at-rest parity with
GitHub). Read [agent-integrations-design.md](./agent-integrations-design.md) for
the architecture; this doc records the plan and what shipped.

**Verified:** the `--user --uid=self` host+tpm2 decrypt build-gate (round-trips);
per-package unit tests (scaffold, skill-config, broker Go, integration-github,
integration-{caldav,contacts,mail}); the broker Go tests drive the REAL
skill-config; `spaces-integrations-nix-eval` (blob credentials + schema),
`spaces-integrations-migrated-nix-eval` (autoRun split), and the profile-aware
`pi-session-integrations-bridge` check (real quickshell + the panel bridge
against the new protocol); the test-machine host evaluates; SettingsWindow +
ProfileEditor parse/instantiate under headless quickshell. **Pending:** live
visual QA of the provisioning form's per-profile delegates (agent-vm) and a
full mail/caldav/contacts e2e against real servers.

**Scope delivered:** three multi-account integrations end to end, the unified
store + broker rework, the panel, and the cutover. **Not** in scope (unchanged):
`google` (OAuth), `signal` (QR channel), and deleting the `skill-config` binary.

## The core realization

`skill-config` already provides everything the broker's fixed-secret model
lacks. From `packages/skill-config/skill_config.py` + `skill-config-daemon`:

- **Multi-account is native** — keys are `<skill>.<profile>.<field>`; profiles
  are created at runtime, no rebuild.
- **Config vs. secret split exists** — schema declares `config:` (→
  `config.toml`, 0644) and `secrets:` (→ `secrets.toml`, 0600); each field is
  one or the other.
- **The GUI provisioning channel exists** — `skill-config request-input`
  blocks on `skill-config-daemon`, which drives the panel via
  `List`/`Submit`/`Cancel`/`subscribe`; the request carries a **`Secret bool`**
  so the panel already knows which fields to mask. This *is* the §5.5 config
  channel — shipped and tested.

The **only** thing wrong with `skill-config` is a location bug: today the
agent runs `skill-config get …password` **inside its own Landlock domain**
against a store in its own reachable FS → req-1 violated. Nothing else about
it is incompatible.

**Fix:** relocate it. The integration's MCP server runs `skill-config get`
*inside the integration's* Landlock domain against a store the agent's domain
is denied; the trusted broker/panel own all **writes**. The agent never
invokes `skill-config` and never sees a secret.

```
agent domain            integration domain (mail)          trusted
┌────────────┐          ┌───────────────────────────┐   ┌──────────────┐
│ pi + tools │ tool     │ MCP server                │   │ panel        │
│   + bash   │ call ───▶│  skill-config get         │   │  request/    │
└────────────┘ (gateway)│   email.work.password ────┼──▶│  submit      │
                        │  reads config/secrets     │   │      │       │
                        │  from $CREDENTIALS_DIR    │   │  spaces-     │
                        └───────────────────────────┘   │  integrationd│
                          StateDir denied to agent ◀─────┤  (writer +   │
                                                         │   sealer)    │
                                                         └──────────────┘
```

## Architecture (Option 3): blob-credential store, TPM-sealed

The static-`LoadCredentialEncrypted` constraint (one blob per name, fixed at
build) is what forced "one instance per account" in the earlier draft. Option
3 sidesteps it: model the **whole** `config.toml` and **whole** `secrets.toml`
as two fixed credentials, with profiles as rows inside.

- Each integration unit gets exactly two credentials:
  - `config`  → `LoadCredential`          (plaintext `config.toml`)
  - `secrets` → `LoadCredentialEncrypted` (host+tpm2-sealed `secrets.toml`)
- The **credential count is fixed** (always `config` + `secrets`) → the static
  constraint is satisfied. **Profiles are dynamic rows** inside the blobs →
  runtime multi-account, no rebuild.
- **At-rest parity with GitHub**: `secrets.toml` is host+tpm2-sealed, not
  plaintext — strictly stronger than today's 0600 `secrets.toml` and equal to
  the GitHub PAT posture.
- The **broker** (`spaces-integrationd`) is the single trusted writer: it
  holds the encrypt/decrypt path, re-seals `secrets.toml` on every change, and
  the integration only ever *reads* the systemd-decrypted blob from
  `$CREDENTIALS_DIRECTORY` at runtime — exactly like GitHub reads its token.

## Verified facts (the machinery we build on)

Probed on the `integrations` branch:

| Fact | Source | Implication |
|---|---|---|
| skill-config store is `<skill>.<profile>.<field>` across `config.toml`/`secrets.toml`, schema-routed | `skill_config.py` `cmd_get/set`, `schema()` | multi-profile + config/secret split already exist |
| `request-input` returns the value to the CLI **and** writes it; prints `saved <key>`, never the value | `skill_config.py` `cmd_request_input` | writer must run in the trusted domain, not the agent; read path (`get`) is agent-domain-safe as it stays behind the wall |
| daemon request carries `Secret bool`; panel List/Submit/Cancel/subscribe | `skill-config-daemon/protocol.go` | the masked/plain GUI provisioning flow already works |
| broker seals scalar secrets `host+tpm2`, name-checked vs definition, `enable` requires all | `spaces-integrationd/server.go` | reworked into blob seal + per-profile completeness |
| unit credential list is fixed at build (`LoadCredentialEncrypted` per name) | `lib.nix` | blob-per-file keeps count fixed while rows stay dynamic |
| integration `StateDirectory`/cred mount denied to the agent's Landlock domain | design §5.4; POC VM probe | the wall that makes relocation safe |
| MCP contract: socket-activated unix socket, newline JSON-RPC `initialize`/`tools/list`/`tools/call`; secret from `$CREDENTIALS_DIRECTORY` | `integration_github.py` | the port template |

**Build-gate to verify first** (mirror the POC's encrypt gate): as the
non-root `tss` user, `systemd-creds decrypt --user --uid=self --name=secrets`
round-trips a `host+tpm2` blob sealed with the same `--name`. The broker needs
decrypt-to-edit; confirm it works user-scoped before building on it.

## Locked decisions

1. **Keep `skill-config`; relocate it behind the wall.** The integration
   domain runs `skill-config get` only (read). The trusted broker/panel own
   every write. Fixes req-1 (location bug); reuses the store format, schema,
   profiles, and provisioning UI wholesale.

2. **Unified blob-credential store; profiles are rows.** Two fixed credentials
   per unit (`config` plain, `secrets` host+tpm2). Multi-account lives inside
   the blobs. TPM-at-rest parity with GitHub.

3. **Broker is the single trusted writer + sealer.** New ops set fields per
   `<integration>.<profile>.<field>`. A secret write: decrypt the `secrets`
   blob (new `--user --uid=self` decrypt path) → edit the row via
   `skill-config` on a **tmpfs** working copy under `%t` (never `%S`) →
   re-seal → discard plaintext. Config writes go straight to the plaintext
   `config` blob. Fold `skill-config-daemon`'s request/submit/subscribe into
   `spaces-integrationd` (design §5.2: the broker "evolves
   skill-config-daemon").

4. **One provisioning model; GitHub migrates onto it.** No second convention
   (repo rule). GitHub becomes a single-profile integration (`config = {}`,
   `secrets = { token }`, profile `default`). A `multiProfile` manifest flag
   toggles whether the panel exposes profile management (off for GitHub).

5. **Schema moves manifest → definition JSON.** The manifest declares
   `config`/`secrets` field schemas (`description`, `required`); `lib.nix`
   lowers them into `/etc/spaces-integrations/<name>.json`. `skill-config`
   gains env overrides — `SKILL_CONFIG_SCHEMA` (JSON schema instead of
   SKILL.md), `SKILL_CONFIG_CONFIG_FILE`/`SKILL_CONFIG_SECRETS_FILE` (point at
   `$CREDENTIALS_DIRECTORY/{config,secrets}`) — so no SKILL.md ships in an
   integration.

6. **Wrap existing backends; `profile` is a tool argument** (default = the
   sole profile; error asking which when several exist and none given):
   - `integration-mail` wraps `himalaya`; the server materializes a himalaya
     config in `StateDirectory` with `auth.cmd = skill-config get
     mail.<profile>.password` and host/port/email/enc from the profile's
     config.
   - `integration-caldav` reuses the tested curl + UID→resource logic:
     refactor `caldav.sh` to read creds from env; the server sets env per call
     from the resolved profile.
   - `integration-contacts` wraps the raw Go `contacts-cli` (already
     `CONTACTS_*`-env-driven); the server sets env from the profile.

7. **Shared Python MCP scaffold** (`packages/spaces-integration-mcp/`):
   extract the JSON-RPC/socket-activation/creds core from
   `integration_github.py`; all four servers build on it.

8. **autoRun = read auto, write confirm** (design §7):

   | Integration | autoRun (no prompt) | confirm-per-call |
   |---|---|---|
   | mail | `envelope_list`, `message_read` | `message_send` |
   | caldav | `list`, `get`, `etag` | `put`, `delete` |
   | contacts | `discover`, `search`, `get`, `backup` | `new`, `edit`, `delete` |

9. **`network = true`; static `connectPorts` covering all profiles' ports.**
   `mail` → `[993 587 465 143 25]`; `caldav`/`contacts` → `[443]`. One
   widening per unit now covers every profile (better than per-account).

10. **Panel: profile-aware form + request/submit prompt.** Salvage the old
    skill-config panel client as reference; the `secret` flag drives masking
    (already in the protocol). New i18n strings across **all 11 locales**.

## What "keep skill-config working" means concretely

- The `skill-config` **binary + store format + schema + the daemon's
  request/submit logic all survive** — relocated into the trusted boundary
  (integration read path + broker writer).
- What is **removed** is only the *agent-facing exposure*: the
  `skills/{email,calendar,contacts}` markdown, their `builtinSkills` entries,
  and the `skill-config` bash-confirm allowlist entry — so the agent can no
  longer run `skill-config` in its own domain.
- Deleting the `skill-config` binary itself waits until `google`/`signal` also
  migrate (they still use the old agent-facing path).

## The steps

One `jj` commit per step. TDD throughout (red → green → refactor per
`AGENTS.md`): write the pytest / Go test / nix-eval assertion first, watch it
fail for the right reason, then implement.

### Step 0 — Shared MCP scaffold
Extract `spaces-integration-mcp`; refactor `integration-github` onto it,
keeping its pytest green (proves the extraction is behaviour-preserving).

### Step 1 — Unified store + broker rework (the load-bearing step)
- **skill-config**: add `SKILL_CONFIG_SCHEMA` / `SKILL_CONFIG_CONFIG_FILE` /
  `SKILL_CONFIG_SECRETS_FILE` env overrides; pytest the new resolution.
- **manifest/lib.nix**: add `config` + `required`; emit exactly the `config`
  (plain) + `secrets` (encrypted blob) credentials; lower the field schema
  into the definition JSON.
- **broker**: profile-aware `list` (profiles + per-field status), `set-field`,
  `remove-profile`, blob seal/unseal (new decrypt env), per-profile
  completeness gate on `enable`; fold in the daemon's request/submit/subscribe.
  Go tests with mocked encrypt/decrypt.
- **GitHub**: migrate to the unified model (profile `default`,
  `multiProfile=false`); its server reads the token from the store; tests
  updated.
- **Acceptance:** broker seals/unseals a multi-profile `secrets.toml`;
  `set-field` round-trips config + secret; `enable` refused until one profile
  is complete; `SO_PEERCRED` still rejects other uids; `spaces-integrations-nix-eval`
  asserts the two-credential lowering + schema in the definition.

### Step 2 — Panel: profile-aware provisioning
Per integration: list profiles; per profile, config fields (plain input) +
secret fields (masked, `[set]`/`[unset]`); add-profile / remove-profile;
enable/disable; render the request/submit prompt (masking from `secret`).
All new strings in every locale.
- **Acceptance:** cheap headless panel check (pattern:
  `pi-session-integrations-bridge`) drives add-profile → set fields → enable
  against a fake broker; i18n parity check passes.

### Step 3 — `integration-caldav` (simplest backend)
Refactor `caldav.sh` → env-driven helper (no skill-config, no profile arg in
the shell); MCP server resolves the profile via `skill-config get`, sets env,
shells per tool `list/get/etag/put/delete`.
- **Acceptance:** pytest vs a stdlib CalDAV mock — tool surface, `If-Match`,
  UID→resource, auth header, error mapping, multi-profile selection.

### Step 4 — `integration-contacts`
Keep the raw Go `contacts-cli`; drop `contacts.sh`. Tools
`discover/search/get/new/edit/delete/backup` (backup → shared dir);
`CONTACTS_*` from the profile.
- **Acceptance:** pytest with a stub `contacts-cli` — env wiring, arg routing,
  backup lands in `$SPACES_INTEGRATION_SHARED_DIR`, multi-profile.

### Step 5 — `integration-mail` (richest surface)
Server materializes a himalaya config per profile in `StateDirectory`
(`auth.cmd` reads the password via skill-config; host/port/email/enc from
config); tools `envelope_list/message_read/message_send`.
- **Acceptance:** pytest — config generation, port→encryption mapping mirrors
  `mail.sh`, arg routing, `-o json` passthrough, multi-profile; himalaya
  mocked.

### Step 6 — Approval / gateway coverage
One driver test (pattern: `pi-session-approval`) proving the decision-8 split
on the new tools: `message_send`/`put`/`delete` prompt; reads auto-run.

### Step 7 — Cutover / removal
- Declare the three integrations where GitHub is declared
  (`hosts/test-machine/integrations.nix`).
- Remove agent-facing exposure: `builtinSkills.{email,calendar,contacts}`,
  the `mail`/`caldav`/`contacts` wrapper packages + PATH placement, and the
  `skill-config` bash-confirm allowlist entry.
- Delete `skills/{email,calendar,contacts}` and the wrapper packages (keep
  himalaya, the raw Go `contacts-cli`, curl as integration deps).
- **Keep** the `skill-config` binary + `skill-config-daemon` logic (now inside
  the broker / integration read path); full deletion waits on google/signal.

## Testing posture
- Cheap focused checks only (`AGENTS.md`): per-integration pytest, broker Go
  tests, `spaces-integrations-nix-eval`, the panel bridge check, one
  approval-split driver, i18n parity.
- **Do NOT** add subtests to `checks/test-machine.nix`.
- A full-boot e2e (mock IMAP/CalDAV/CardDAV in a VM) only if cross-subsystem
  wiring genuinely demands it — `integration-poc-machine` already proves
  enable→provision→launch→Landlock-wall generically and these reuse it.

## Risks / open questions
- **Broker decrypt-to-edit** — hinges on the build-gate above (`systemd-creds
  decrypt --user --uid=self` on a `host+tpm2` blob). If user-scoped decrypt is
  unavailable, fall back to Option 2 (integration-owned plaintext-0600 store,
  no TPM at rest — still req-1-safe, still multi-account).
- **Transient plaintext during edit** — lives on tmpfs (`%t`) for the duration
  of one `set-field`, never on `%S`. Acceptable (systemd already decrypts creds
  into a runtime mount at unit start).
- **GitHub migration churn** — re-tests a shipped integration; the payoff is
  one broker/store code path instead of two.
- **himalaya surface (step 5)** — if mapping every subcommand is too broad,
  scope mail to `list`/`read`/`send` and expand later.
- **Static ports/hosts (decision 9)** — fixed at manifest build; custom-port
  servers need a per-unit widen (same class as the deferred per-host proxy).
- **Integration-socket peer-auth bypass** — the existing POC residual applies
  unchanged; not introduced or closed here.

## Deferred (out of this plan)
- Agent-*proposed* provisioning/enable (req-11, §5.6) — the panel/user drives
  provisioning; the agent may trigger a prompt but never enables.
- `google` (OAuth) and `signal` (QR channel) migrations; deleting the
  `skill-config` binary.
- Per-host network proxy (§3F); custom-port accounts beyond the manifest set.
