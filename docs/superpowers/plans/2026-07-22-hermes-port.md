# Hermes Agent Port (hyperconfig → spaces) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the per-user hermes-agent microvm stack from `~/synced/projects/hyperconfig` into spaces as a productized desktop feature (default-on, credentials-only brain, seed-once model), then cut hyperconfig over to consume it.

**Architecture:** `modules/nixos/hermes/` (blueprint-published as `nixosModules.hermes`) hosts the ported module tree; simplex is dropped entirely. Productization: auto-provision VMs for normal users gated on a "brain" (openrouter key / llama-swap / explicit `initialModel` / per-user `*_API_KEY`), never pin a model in Nix (seed-once instead), rename pi-chat's openrouter option to `spaces.openrouter`. Spec: `docs/superpowers/specs/2026-07-22-hermes-port-design.md`.

**Tech Stack:** NixOS module system, microvm.nix (qemu/virtiofs/vsock), upstream `github:NousResearch/hermes-agent` NixOS module, blueprint check discovery, `pkgs.testers.runNixOSTest`.

## Global Constraints

- **No simplex anywhere**: `simplex-chat.nix`, `simplex-chat-package.nix`, `simplex.*` options, `SIMPLEX_*` env wiring, the DM-fix plugin — none of it is ported.
- `hermes-agent` flake input MUST NOT follow our nixpkgs (upstream-tested python closure; guest-only).
- `microvm` flake input MUST follow our nixpkgs (host units must match our qemu/virtiofsd).
- The module MUST NOT write model keys into guest config (`settings ? model` is asserted away); model comes from `initialModel` seed-once only.
- Secret-bearing options take host paths (strings/paths passed by value), never content.
- Option namespace stays `services.hermes-microvm`; per-secret credential names ≤ 28 chars (qemu fw_cfg).
- No formatters/linters/full `nix flake check` per task; targeted eval/build commands only. Full check once at the end.
- Source tree for the port: `../hyperconfig/modules/nixos/hermes/` (read it; hyperconfig is a sibling checkout).

## Dependency Map

- Task 1 (flake inputs): no dependencies
- Task 2 (installer uid): no dependencies
- Task 3 (openrouter rename): no dependencies
- Task 4 (faithful port): depends on 1
- Task 5 (productization): depends on 3, 4
- Task 6 (hermes-nix-eval check): depends on 5
- Task 7 (debug hermes-vm test): depends on 5
- Task 8 (docs): depends on 5
- Task 9 (hyperconfig cutover): depends on 5 (run only after 6 and 7 are green)

Waves:
1. Tasks 1, 2, 3
2. Task 4
3. Task 5
4. Tasks 6, 7, 8
5. Task 9 (separate repo: `../hyperconfig`)

---

### Task 1: Flake inputs (`hermes-agent`, `microvm`)

**Files:**
- Modify: `flake.nix:4-23` (inputs attrset)
- Modify: `flake.lock` (via `nix flake lock`)

**Interfaces:**
- Consumes: nothing
- Produces: `inputs.hermes-agent` (upstream flake: `nixosModules.default`, `packages.<sys>.default`, `packages.<sys>.desktop`), `inputs.microvm` (`nixosModules.host`) — Task 4's module tree references both by exactly these names.

**Depends on:** none

- [ ] **Step 1: Add the inputs.** In `flake.nix`, after the `systems` input (line 22), add:

```nix
    # Hermes agent microvms (modules/nixos/hermes). hermes-agent deliberately
    # does NOT follow our nixpkgs: the pin carries its own uv2nix/pyproject
    # python closure (upstream-tested wheels) and only runs inside guests.
    hermes-agent.url = "github:NousResearch/hermes-agent";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
```

- [ ] **Step 2: Lock.**

Run: `nix flake lock`
Expected: `flake.lock` gains `hermes-agent` (with its own `nixpkgs`, `uv2nix`, `pyproject-nix` nodes) and `microvm` nodes; no changes to existing pins.

- [ ] **Step 3: Verify the outputs exist.**

Run: `nix eval .#inputs 2>/dev/null; nix flake metadata --json | jq -r '.locks.nodes | has("hermes-agent"), has("microvm")'`
Expected: `true` / `true`.

---

### Task 2: Installer declares `uid = 1000` for the primary user

**Files:**
- Modify: `packages/calamares-spaces-extensions/files/main.py:144-150` (the `cfgusers` template)
- Test: `debug/installer-config-gen/test_render.py:193-196`

**Interfaces:**
- Consumes: nothing
- Produces: installer-generated configs carry `users.users.<name>.uid = 1000` — the eval-time uid Task 5's auto-provisioning reads.

**Depends on:** none

- [ ] **Step 1: Write the failing test.** In `debug/installer-config-gen/test_render.py`, the existing assertions around lines 193-196 check the rendered user stanza (`users.users.alice = {`, description, extraGroups). Add beside them:

```python
    assert "uid = 1000;" in rendered
```

- [ ] **Step 2: Run it, watch it fail on the assertion** (not on import):

Run: `nix build .#debug.x86_64-linux.installer-config-gen -L`
Expected: FAIL with `AssertionError` on the `uid = 1000;` assertion.

- [ ] **Step 3: Extend the template.** In `packages/calamares-spaces-extensions/files/main.py`, change `cfgusers`:

```python
cfgusers = """  # Define a user account. Don't forget to set a password with 'passwd'.
  users.users.@@username@@ = {
    isNormalUser = true;
    # First user on a fresh install: userborn/useradd deterministically
    # allocates 1000. Declared so eval-time consumers (hermes microvms
    # derive ports/CID/MAC from it) can see it.
    uid = 1000;
    description = "@@fullname@@";
    extraGroups = [ "networkmanager" "wheel" ];
  };

"""
```

- [ ] **Step 4: Run test to verify it passes.**

Run: `nix build .#debug.x86_64-linux.installer-config-gen -L`
Expected: PASS.

---

### Task 3: `spaces.openrouter` (rename from `services.pi-chat.openrouter`)

**Files:**
- Create: `modules/nixos/openrouter.nix`
- Modify: `modules/nixos/pi-chat/default.nix` (delete option block :545-558 and assertion :607-610; rewire reads at :658, :894, :908, :910; update header comment :21)
- Modify: `modules/nixos/default.nix` (import the new module in the base list)
- Modify: `hosts/test-machine/openrouter.nix:59-62,78-81` (migrate callsites)
- Create: `checks/hermes-openrouter-rename-eval/default.nix`

**Interfaces:**
- Consumes: nothing
- Produces: `spaces.openrouter.enable :: bool`, `spaces.openrouter.apiKeyFile :: nullOr path` — Task 5 reads both for brain derivation and `secretEnv` injection. Old `services.pi-chat.openrouter.{enable,apiKeyFile}` paths keep evaluating via `mkRenamedOptionModule`.

**Depends on:** none

- [ ] **Step 1: Write the failing eval check.** Create `checks/hermes-openrouter-rename-eval/default.nix`:

```nix
# Pins the services.pi-chat.openrouter.* -> spaces.openrouter.* rename:
# the old path must still evaluate (mkRenamedOptionModule) and land in
# the new one; the new path must feed pi-chat's secret staging.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  keyFile = pkgs.writeText "openrouter-api-key" "sk-or-dummy";

  # Old path set -> value must arrive at the new path.
  renamed =
    (inputs.self.lib.mkMinimalEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        inputs.self.nixosModules.openrouter
        {
          services.pi-chat.openrouter.enable = true;
          services.pi-chat.openrouter.apiKeyFile = keyFile;
        }
      ];
    }).config;

  ok =
    assert renamed.spaces.openrouter.enable;
    assert renamed.spaces.openrouter.apiKeyFile == keyFile;
    true;
in
assert ok;
pkgs.runCommand "hermes-openrouter-rename-eval" { } "touch $out"
```

- [ ] **Step 2: Run it, watch it fail for the right reason** (module missing):

Run: `nix build .#checks.x86_64-linux.hermes-openrouter-rename-eval -L`
Expected: FAIL — `attribute 'openrouter' missing` on `inputs.self.nixosModules`.

- [ ] **Step 3: Create `modules/nixos/openrouter.nix`:**

```nix
# spaces.openrouter — the host-wide OpenRouter API key shared by every
# agent surface (pi-chat staging, hermes microvm credentials). Options
# only, zero closure; safe in the base tree. Consumers stage/transport
# the key themselves.
{ config, lib, ... }:
{
  imports = [
    (lib.mkRenamedOptionModule
      [ "services" "pi-chat" "openrouter" "enable" ]
      [ "spaces" "openrouter" "enable" ])
    (lib.mkRenamedOptionModule
      [ "services" "pi-chat" "openrouter" "apiKeyFile" ]
      [ "spaces" "openrouter" "apiKeyFile" ])
  ];

  options.spaces.openrouter = {
    enable = lib.mkEnableOption "the shared OpenRouter API key for agent surfaces";
    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Host path to a file containing the OpenRouter API key (single
        line). Pass a runtime path (e.g. a sops/clan secret), not a
        store path, outside tests. pi-chat stages it under
        /run/spaces-secrets; hermes microvms ride it in as a systemd
        credential.
      '';
    };
  };

  config.assertions = [
    {
      assertion = !config.spaces.openrouter.enable || config.spaces.openrouter.apiKeyFile != null;
      message = "spaces.openrouter.apiKeyFile must be set when spaces.openrouter.enable = true.";
    }
  ];
}
```

- [ ] **Step 4: Rewire pi-chat.** In `modules/nixos/pi-chat/default.nix`:
  - Delete the `openrouter = { … };` option block (lines 545-558) and the apiKeyFile assertion (lines 607-610 — now lives in openrouter.nix).
  - Add near the top of the module body a let-binding `orCfg = config.spaces.openrouter;` and replace every `cfg.openrouter.enable` → `orCfg.enable`, `cfg.openrouter.apiKeyFile` → `orCfg.apiKeyFile` (lines 658, 894, 908, 910).
  - Header comment line 21: `(when openrouter.enable = true; …)` → `(when spaces.openrouter.enable = true; …)`.
  - If pi-chat's module does not already import other self modules, add `inputs.self.nixosModules.openrouter` to its `imports` so standalone evals (checks) see the option. It is a plain path — deduped when a full system also imports it via the base list.

- [ ] **Step 5: Import in the base list.** In `modules/nixos/default.nix`, add `inputs.self.nixosModules.openrouter` to the base imports (alongside the other always-safe modules; it is options-only).

- [ ] **Step 6: Migrate in-repo callsites.** In `hosts/test-machine/openrouter.nix`: lines 59/62 and 78-81 — change `openrouter.enable` / `openrouter.apiKeyFile` under `services.pi-chat` to `spaces.openrouter.enable` / `spaces.openrouter.apiKeyFile` (top-level, not under `services.pi-chat`).

- [ ] **Step 7: Run the check + affected evals.**

Run: `nix build .#checks.x86_64-linux.hermes-openrouter-rename-eval -L`
Expected: PASS.
Run: `nix build .#nixosConfigurations.test-machine.config.system.build.toplevel --no-link`
Expected: success (rename warning acceptable only if some in-repo file still uses the old path — there must be none; grep `pi-chat.openrouter` across the repo → only the mkRenamedOptionModule lines and docs).

---

### Task 4: Faithful port of the module tree (simplex-free)

**Files:**
- Create: `modules/nixos/hermes/{default,options,vms,guest,guest-python,host,firewall,cli,scripts,lib}.nix` (copied from `../hyperconfig/modules/nixos/hermes/`, then edited)

**Interfaces:**
- Consumes: `inputs.hermes-agent`, `inputs.microvm` (Task 1)
- Produces: `nixosModules.hermes` exposing `services.hermes-microvm.{enable,settings,environment,extraPlugins,extraPackages,pythonPackages,vcpu,mem,gpu,users}` with `users.<n>.{uid,dashboardPort,spacesPort,environment,secretEnv,spacesGateway}` — Task 5 modifies this tree in place.

**Depends on:** 1

- [ ] **Step 1: Copy the ten files** (NOT `site.nix`, `guest-python-test.nix`, `simplex-chat.nix`, `simplex-chat-package.nix`):

Run:
```sh
mkdir -p modules/nixos/hermes
cp ../hyperconfig/modules/nixos/hermes/{default,options,vms,guest,guest-python,host,firewall,cli,scripts,lib}.nix modules/nixos/hermes/
```

- [ ] **Step 2: Strip simplex from `options.nix`** — delete the whole `simplex = { … };` block (source lines 115-122: `enable` mkEnableOption + `allowedUsers`), and drop the now-dangling blank line.

- [ ] **Step 3: Strip simplex from `guest.nix`:**
  - Delete `./simplex-chat.nix` from the guest `imports` (source line 37).
  - Delete the simplex service/bind-mount block (source lines 40-51: the comment, `services.simplex-chat-daemon = lib.mkIf cfg.simplex.enable { … };`, and `fileSystems."/var/lib/simplex-chat" = lib.mkIf cfg.simplex.enable { … };`).
  - Simplify the hermes-agent environment (source lines 225-233) to:

```nix
    environment = cfg.environment // ucfg.environment;
```

- [ ] **Step 4: Sanity-grep.**

Run: `grep -rni simplex modules/nixos/hermes/`
Expected: no output.

- [ ] **Step 5: Eval-smoke the module.**

Run:
```sh
nix eval --impure --expr '
  let f = builtins.getFlake (toString ./.);
  in ((f.lib.mkMinimalEvalSystem {
    system = "x86_64-linux";
    modules = [
      f.nixosModules.hermes
      { services.hermes-microvm.enable = false; }
    ];
  }).config.services.hermes-microvm.enable)'
```
Expected: `false` (module imports cleanly, including `inputs.microvm.nixosModules.host`).

- [ ] **Step 6: Eval one VM end-to-end (pre-productization shape).**

Run:
```sh
nix eval --impure --expr '
  let f = builtins.getFlake (toString ./.);
  in (builtins.attrNames (f.lib.mkMinimalEvalSystem {
    system = "x86_64-linux";
    modules = [
      f.nixosModules.hermes
      {
        users.users.alice = { isNormalUser = true; uid = 1000; group = "users"; };
        services.hermes-microvm = {
          enable = true;
          users.alice.uid = 1000;
        };
      }
    ];
  }).config.microvm.vms)'
```
Expected: `[ "hermes-alice" ]`.

---

### Task 5: Productization

**Files:**
- Modify: `modules/nixos/hermes/options.nix` (new options, submodule defaults, derivation config, assertions, warnings)
- Modify: `modules/nixos/hermes/default.nix` (import `inputs.self.nixosModules.openrouter`; header layout note)
- Modify: `modules/nixos/hermes/{vms,host,firewall,cli}.nix` (`cfg.users` → `cfg.enabledUsers` for wiring; assertions keep `cfg.users`)
- Modify: `modules/nixos/hermes/guest.nix` (seed-once model snippet in `systemd.services.hermes-agent.preStart`)
- Modify: `modules/nixos/hermes/firewall.nix` (llama-swap egress rule)
- Modify: `modules/nixos/spaces.nix` (desktop composition)

**Interfaces:**
- Consumes: `spaces.openrouter.{enable,apiKeyFile}` (Task 3); `nixosModules.hermes` tree (Task 4); `config.services.llama-swap.{enable,port}` (guarded with `or`, module not required); `config.services.spaces-integrations.enable` (guarded with `or false`).
- Produces: `services.hermes-microvm.provisionNormalUsers :: bool = true`; `services.hermes-microvm.initialModel :: nullOr { provider, base_url, default }`; `services.hermes-microvm.users.<n>.enable :: bool = true`; internal `services.hermes-microvm.enabledUsers` (the filtered attrset all wiring iterates). Tasks 6-8 exercise these.

**Depends on:** 3, 4

- [ ] **Step 1: Extend `options.nix`.** Replace the file's header comment and extend. The full new shape (keep the existing options not shown here — `settings`, `environment`, `extraPlugins`, `extraPackages`, `pythonPackages`, `vcpu`, `mem`, `gpu` — verbatim):

```nix
# Option interface of services.hermes-microvm, the auto-provisioning /
# brain derivation, and the assertions that validate it (uids must be
# unique and declared — they derive ports, MAC and firewall identity;
# secretEnv names ride qemu fw_cfg and are length-limited; settings may
# never pin a model — that would clobber the user's runtime choice on
# every boot).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.hermes-microvm;
  hostConfig = config;
  orCfg = config.spaces.openrouter;
  llamaOn = config.services.llama-swap.enable or false;
  llamaPort = config.services.llama-swap.port or 8012;
  normalUsers = lib.filterAttrs (_: u: u.isNormalUser) config.users.users;
  # A VM without a model source is a dead qemu reserving RAM: only
  # provision when SOME brain exists for the user.
  userHasBrain =
    ucfg:
    orCfg.enable
    || llamaOn
    || cfg.initialModel != null
    || lib.any (n: lib.hasSuffix "_API_KEY" n) (lib.attrNames ucfg.secretEnv);
in
{
  options.services.hermes-microvm = with lib; {
    enable = mkEnableOption "per-user Hermes agent MicroVMs";

    provisionNormalUsers = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Auto-provision a VM for every isNormalUser. Each such user needs
        a declared users.users.<n>.uid (the installer declares 1000 for
        the primary user). Opt out per user via
        services.hermes-microvm.users.<n>.enable = false. When this is
        false, only explicitly declared users get VMs.
      '';
    };

    initialModel = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            provider = mkOption { type = types.str; };
            base_url = mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            default = mkOption { type = types.str; };
          };
        }
      );
      default = null;
      defaultText = literalExpression ''
        null when spaces.openrouter.enable (credentials suffice — hermes
        picks the provider's catalog default on first run); the local
        llama-swap endpoint when services.llama-swap.enable; else null.
      '';
      description = ''
        Seed-once model: written into the guest's config.yaml only when
        no model is configured there, then never touched again — so the
        user's runtime model switches (TUI /model) persist across
        reboots. NEVER set settings.model (asserted): the upstream
        activation re-merges Nix settings every boot and would clobber
        the choice.
      '';
    };

    # …existing options: settings, environment, extraPlugins,
    # extraPackages, pythonPackages, vcpu, mem, gpu — UNCHANGED…

    users = mkOption {
      default = { };
      description = "Users that get their own Hermes microvm.";
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether this user gets a VM.";
              };
              uid = mkOption {
                type = types.nullOr types.int;
                default = hostConfig.users.users.${name}.uid or null;
                defaultText = literalExpression "config.users.users.<name>.uid";
                description = "The user's uid on the host (mirrored in the guest); derives ports, vsock CID and MAC.";
              };
              dashboardPort = mkOption {
                type = types.port;
                default = 22100 + config.uid - 1000;
                description = "Host 127.0.0.1 port forwarded to the guest dashboard.";
              };
              spacesPort = mkOption {
                type = types.port;
                default = 22200 + config.uid - 1000;
                description = "Host 127.0.0.1 port of the spaces gateway TCP bridge.";
              };
              environment = mkOption {
                type = types.attrsOf types.str;
                default = { };
                description = "Per-user non-secret env vars for the guest's hermes .env.";
              };
              secretEnv = mkOption {
                type = types.attrsOf types.str;
                default = lib.optionalAttrs (orCfg.enable && orCfg.apiKeyFile != null) {
                  OPENROUTER_API_KEY = toString orCfg.apiKeyFile;
                };
                defaultText = literalExpression ''{ OPENROUTER_API_KEY = spaces.openrouter.apiKeyFile; } when spaces.openrouter is enabled'';
                description = ''
                  Env var name -> host file path (raw secret value, no KEY=
                  prefix). Each entry rides a systemd credential into the
                  guest (qemu fw_cfg) and is rewritten into $HERMES_HOME/.env
                  before the agent starts. Names are limited to 28 chars.
                  NOTE: defining this replaces the openrouter default —
                  re-add OPENROUTER_API_KEY if you add other secrets.
                '';
              };
              spacesGateway = {
                enable = mkOption {
                  type = types.bool;
                  default = hostConfig.services.spaces-integrations.enable or false;
                  defaultText = literalExpression "config.services.spaces-integrations.enable";
                  description = "Bridge the user's spaces integration gateway into the VM.";
                };
                socket = mkOption {
                  type = types.str;
                  default = "/run/user/${toString config.uid}/spaces-integration-gateway.sock";
                  description = "The per-user spaces gateway socket on the host.";
                };
              };
            };
          }
        )
      );
    };

    enabledUsers = mkOption {
      internal = true;
      readOnly = true;
      type = types.attrsOf types.raw;
      description = "users filtered to entries that actually get a VM: enabled, uid declared, brain available. All host/guest wiring iterates this.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Auto-provision: an EMPTY definition per normal user — every value
    # (uid, gateway, openrouter secret) flows from submodule defaults, so
    # explicitly declared users behave identically.
    services.hermes-microvm.users = lib.mkIf cfg.provisionNormalUsers (
      lib.mapAttrs (_: _: { }) normalUsers
    );

    services.hermes-microvm.enabledUsers = lib.filterAttrs (
      _: u: u.enable && u.uid != null && userHasBrain u
    ) cfg.users;

    services.hermes-microvm.initialModel = lib.mkDefault (
      if orCfg.enable then
        null
      else if llamaOn then
        {
          provider = "custom";
          # slirp's alias for the host loopback; firewall.nix opens the
          # matching per-VM egress rule.
          base_url = "http://10.0.2.2:${toString llamaPort}/v1";
          default = "gemma4:e4b";
        }
      else
        null
    );

    warnings =
      lib.optional (cfg.users != { } && cfg.enabledUsers == { })
        "services.hermes-microvm: enabled, but no VM is provisioned — no brain is configured (enable spaces.openrouter or services.llama-swap, set initialModel, or add a *_API_KEY secretEnv) or every user is disabled.";

    assertions =
      [
        {
          assertion = !(cfg.settings ? model);
          message = "services.hermes-microvm.settings.model is re-merged into the guest config on EVERY boot and would clobber the user's runtime model choice. Use services.hermes-microvm.initialModel (seed-once) instead.";
        }
      ]
      ++ lib.mapAttrsToList (user: ucfg: {
        assertion = !(ucfg.enable && ucfg.uid == null);
        message = "services.hermes-microvm.users.${user}: no uid. Declare users.users.${user}.uid (the installer declares 1000 for the primary user) or set services.hermes-microvm.users.${user}.enable = false.";
      }) cfg.users
      ++ lib.mapAttrsToList (user: ucfg: {
        assertion =
          ucfg.uid == null
          || lib.count (u: u.uid != null && u.uid == ucfg.uid) (lib.attrValues cfg.users) == 1;
        message = "services.hermes-microvm: duplicate uid ${toString ucfg.uid} (${user}) — uids derive ports, MAC and firewall identity and must be unique";
      }) cfg.users
      ++ lib.concatLists (
        lib.mapAttrsToList (
          user: ucfg:
          map (name: {
            assertion = builtins.stringLength name <= 28;
            message = "services.hermes-microvm.users.${user}.secretEnv.${name}: credential names must be <= 28 chars (qemu fw_cfg name limit)";
          }) (lib.attrNames ucfg.secretEnv)
        ) cfg.users
      );
  };
}
```

Note the existing uid-uniqueness assertion is replaced by the null-guarded version above; keep the fw_cfg length assertion as-is (shown).

- [ ] **Step 2: Switch wiring to `enabledUsers`.** In `vms.nix`, `host.nix`, `firewall.nix`, `cli.nix`: every iteration over `cfg.users` (`lib.mapAttrs`, `lib.mapAttrs'`, `lib.mapAttrsToList`, `forEachUser`, `userCaseArms`) becomes `cfg.enabledUsers`. Do NOT touch `options.nix` assertions (they validate all declared users). Grep to confirm:

Run: `grep -n 'cfg\.users' modules/nixos/hermes/*.nix`
Expected: hits only in `options.nix`.

- [ ] **Step 3: Seed-once model in `guest.nix`.** In the `let` of the guest module function add (only used when non-null):

```nix
  # Seed-once model: written to config.yaml ONLY when no model is
  # configured, then sentinel'd — the user's runtime /model choice is
  # never clobbered. Runs in preStart (after upstream activation created
  # config.yaml from Nix settings, which never contain model keys).
  modelSeedScript = lib.optionalString (cfg.initialModel != null) ''
    sentinel=${guestStateDir}/.hermes/.model-seeded
    if [ ! -e "$sentinel" ]; then
      ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3 - \
        ${guestStateDir}/.hermes/config.yaml <<'SEED'
    import sys, os, yaml
    path = sys.argv[1]
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            data = yaml.safe_load(f) or {}
    if not data.get("model"):
        data["model"] = ${
          builtins.toJSON (
            lib.filterAttrs (_: v: v != null) {
              inherit (cfg.initialModel) provider base_url;
              default = cfg.initialModel.default;
            }
          )
        }
        with open(path, "w") as f:
            yaml.dump(data, f, default_flow_style=False)
    SEED
      touch "$sentinel"
    fi
  '';
```

Append `${modelSeedScript}` at the end of `systemd.services.hermes-agent.preStart` (after the credentials block). Mind heredoc indentation: the `<<'SEED'` body must start at column 0 relative to the shell — use the exact layout above (Nix strips the common indent).

- [ ] **Step 4: llama-swap egress rule in `firewall.nix`.** In the `let`, add `llamaOn`/`llamaPort` bindings (same `or`-guarded shape as options.nix). Inside `firewallRules`' per-user block, BEFORE the final `-j REJECT` line for `vmUser user`, add:

```nix
    ${lib.optionalString llamaOn ''
      # local brain: the guest reaches llama-swap via slirp's host alias
      # (10.0.2.2 -> host loopback); without this the trailing owner
      # REJECT kills it.
      iptables -w -A hermes-microvm -p tcp --dport ${toString llamaPort} -m owner --uid-owner ${vmUser user} -j RETURN
    ''}
```

- [ ] **Step 5: Compose into the desktop.** In `modules/nixos/spaces.nix`: add `inputs.self.nixosModules.hermes` to `imports` (with comment `# hermes agent microvms (one untrusted-agent VM per user)`), and inside the `(lib.mkIf (config.spaces.profile == "desktop") { … })` block add:

```nix
      services.hermes-microvm.enable = lib.mkDefault true;
```

- [ ] **Step 6: Import openrouter into the hermes module.** In `modules/nixos/hermes/default.nix` imports, add `inputs.self.nixosModules.openrouter` (needed for standalone/check evals; path-deduped in full systems). Update the header layout comment: drop nothing, add `#   (spaces.openrouter — shared key option — imported from ../openrouter.nix)`.

- [ ] **Step 7: Eval-verify the productized shape** (this is pre-Task-6 smoke; the real contract lives in the check):

Run:
```sh
nix eval --impure --expr '
  let f = builtins.getFlake (toString ./.);
      sys = mods: (f.lib.mkMinimalEvalSystem { system = "x86_64-linux"; modules = mods; }).config;
      base = {
        users.users.alice = { isNormalUser = true; uid = 1000; group = "users"; };
        services.hermes-microvm.enable = true;
      };
      or1 = sys [ f.nixosModules.hermes base
        { spaces.openrouter = { enable = true; apiKeyFile = "/run/secrets/or-key"; }; } ];
  in {
    vms = builtins.attrNames or1.microvm.vms;
    key = or1.services.hermes-microvm.enabledUsers.alice.secretEnv.OPENROUTER_API_KEY;
    seed = or1.services.hermes-microvm.initialModel == null;
  }'
```
Expected: `{ key = "/run/secrets/or-key"; seed = true; vms = [ "hermes-alice" ]; }`.

- [ ] **Step 8: test-machine still builds** (it now default-enables hermes via the desktop profile; its `test` user has uid 1000 and openrouter is enabled there):

Run: `nix build .#nixosConfigurations.test-machine.config.system.build.toplevel --no-link`
Expected: success. If it fails on hermes RAM/closure grounds in the test VM context, set `services.hermes-microvm.enable = lib.mkForce false;` in `hosts/test-machine/configuration.nix` with a comment (`# hermes VMs: nested qemu is exercised by debug.hermes-vm, not the interactive test VM`) — decide by build result, and record the choice in the commit message.

---

### Task 6: `checks/hermes-nix-eval`

**Files:**
- Create: `checks/hermes-nix-eval/default.nix`

**Interfaces:**
- Consumes: everything Task 5 produces (`provisionNormalUsers`, `initialModel`, `enabledUsers` semantics, assertions, firewall rule, seed snippet).
- Produces: nothing (leaf check).

**Depends on:** 5

- [ ] **Step 1: Write the check.** Create `checks/hermes-nix-eval/default.nix`:

```nix
# Cheap nix-eval contract for the hermes microvm module's productized
# behavior (docs/superpowers/specs/2026-07-22-hermes-port-design.md):
#   - default-on provisioning for uid-declared normal users, per-user
#     opt-out, provisionNormalUsers opt-out;
#   - brain gating: no openrouter/llama-swap/initialModel/API-key ->
#     no VMs + a warning;
#   - brain derivation: openrouter -> secretEnv key + initialModel null;
#     llama-swap -> seed tuple + firewall egress + seed-once preStart;
#   - guard rails: settings.model and uid-less users are assertion
#     failures (checked as failed assertion messages, not by building).
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  sys =
    mods:
    (inputs.self.lib.mkMinimalEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [ inputs.self.nixosModules.hermes ] ++ mods;
    }).config;

  alice = {
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };
  };
  on = { services.hermes-microvm.enable = true; };
  withOpenrouter = {
    spaces.openrouter = {
      enable = true;
      apiKeyFile = "/run/secrets/openrouter-key";
    };
  };

  failedAssertions = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  # 1. openrouter brain: VM exists, key injected, no model seeded.
  orSys = sys [ alice on withOpenrouter ];
  # 2. llama-swap brain: seed tuple + firewall egress + preStart seed.
  llamaSys = sys [
    alice
    on
    inputs.self.nixosModules.llama-swap
    { services.llama-swap.enable = true; }
  ];
  guestOf = cfg: name: cfg.microvm.vms.${name}.config.config;
  llamaGuest = guestOf llamaSys "hermes-alice";
  # 3. no brain: no VMs, one warning.
  noBrain = sys [ alice on ];
  # 4. opt-outs.
  optOutUser = sys [ alice on withOpenrouter { services.hermes-microvm.users.alice.enable = false; } ];
  optOutAll = sys [ alice on withOpenrouter { services.hermes-microvm.provisionNormalUsers = false; } ];
  # 5. guard rails (eval assertions, never built).
  uidless = sys [
    on
    withOpenrouter
    { users.users.bob = { isNormalUser = true; group = "users"; }; }
  ];
  modelPin = sys [ alice on withOpenrouter { services.hermes-microvm.settings.model = "openrouter/foo"; } ];

  ok =
    assert builtins.attrNames orSys.microvm.vms == [ "hermes-alice" ];
    assert orSys.services.hermes-microvm.enabledUsers.alice.secretEnv.OPENROUTER_API_KEY
      == "/run/secrets/openrouter-key";
    assert orSys.services.hermes-microvm.initialModel == null;
    assert !(lib.hasInfix ".model-seeded" (guestOf orSys "hermes-alice").systemd.services.hermes-agent.preStart);

    assert llamaSys.services.hermes-microvm.initialModel.base_url == "http://10.0.2.2:8012/v1";
    assert llamaSys.services.hermes-microvm.initialModel.default == "gemma4:e4b";
    assert lib.hasInfix ".model-seeded" llamaGuest.systemd.services.hermes-agent.preStart;
    assert lib.hasInfix "--dport 8012 -m owner" llamaSys.networking.firewall.extraCommands;

    assert noBrain.microvm.vms == { };
    assert lib.any (w: lib.hasInfix "no brain" w) noBrain.warnings;

    assert optOutUser.microvm.vms == { };
    assert optOutAll.microvm.vms == { };

    assert lib.any (m: lib.hasInfix "users.bob: no uid" m) (failedAssertions uidless);
    assert lib.any (m: lib.hasInfix "initialModel" m) (failedAssertions modelPin);
    true;
in
assert ok;
pkgs.runCommand "hermes-nix-eval" { } "touch $out"
```

- [ ] **Step 2: Run it.**

Run: `nix build .#checks.x86_64-linux.hermes-nix-eval -L`
Expected: PASS. (If the `microvm.vms.<n>.config.config` guest-access path differs in the pinned microvm.nix, adjust `guestOf` to the actual submodule shape — inspect with `nix eval … .microvm.vms."hermes-alice" --apply builtins.attrNames`.)

---

### Task 7: `debug.x86_64-linux.hermes-vm` (heavy, nested)

**Files:**
- Create: `debug/hermes-vm.nix`
- Modify: `flake.nix:45-51` (append `"hermes-vm"` to `debugTests`)

**Interfaces:**
- Consumes: Task 5's default-on provisioning; `spaces.openrouter`; the `hermes` shim and dashboard socket from the ported tree.
- Produces: nothing (leaf test).

**Depends on:** 5

- [ ] **Step 1: Check the inner accel fallback.** The guest must boot under TCG when the outer test VM has no `/dev/kvm`:

Run: `grep -rn 'accel' $(nix flake metadata --json | jq -r '.locks.nodes.microvm.locked | "\(.type):\(.owner)/\(.repo)/\(.rev)"' | xargs -I{} nix flake prefetch {} --json | jq -r .storePath)/lib/runners/qemu.nix | head`
Expected: an `accel=kvm:tcg`-style machine flag (TCG fallback built in). If instead qemu is invoked with a bare `-enable-kvm`, stop and surface this — the test then needs `microvm.qemu.extraArgs` plumbing and that is a design conversation, not an improvisation.

- [ ] **Step 2: Write the test.** Create `debug/hermes-vm.nix`:

```nix
# Full-boot hermes microvm test: desktop-role provisioning (default-on,
# auto-provisioned uid-1000 user), the vsock ssh shim, the dashboard
# forward socket, and the guest python venv contract (folded in from
# hyperconfig's old guest-python-test.nix) — all against the REAL guest.
#
# Nested virtualization: the inner qemu falls back to TCG without
# nested KVM; allow several minutes. Deliberately NOT the full
# nixosModules.spaces desktop (voxtype's ASR closure and greetd add
# gigabytes and minutes for zero hermes coverage).
{ pkgs, inputs, system, flake }:
pkgs.testers.runNixOSTest {
  name = "hermes-vm";

  nodes.machine = {
    imports = [
      inputs.self.nixosModules.hermes
      inputs.self.nixosModules.openrouter
    ];
    virtualisation.cores = 4;
    virtualisation.memorySize = 6144;
    virtualisation.diskSize = 16 * 1024;

    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };

    services.hermes-microvm.enable = true;
    # Dummy key: satisfies brain gating; the gateway starts fine with a
    # bogus key (model resolution is per-message).
    spaces.openrouter = {
      enable = true;
      apiKeyFile = pkgs.writeText "openrouter-key" "sk-or-dummy";
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Auto-provisioned VM comes up (TCG: generous timeout).
    machine.wait_for_unit("microvm@hermes-alice.service", timeout=300)

    # Guest sshd reachable over vsock: exercise the REAL `hermes` shim
    # path end to end. The shim needs a login-ish environment.
    machine.wait_until_succeeds(
        "runuser -u alice -- hermes --version",
        timeout=1200,
    )

    # Dashboard forward socket is bound (root-held, squat-proof).
    machine.succeed("systemctl is-active hermes-dashboard-fwd-alice.socket")

    # Guest python contract (old guest-python-test, against the real
    # guest): ssh through the same vsock route the shim uses.
    ssh = (
        "runuser -u alice -- ssh -q"
        " -i /var/lib/hermes-microvm/alice/ssh/client_ed25519"
        " -o UserKnownHostsFile=/var/lib/hermes-microvm/alice/ssh/known_hosts"
        " -o StrictHostKeyChecking=yes -o HostKeyAlias=hermes-alice"
        " -o ProxyCommand='${pkgs.systemd}/lib/systemd/systemd-ssh-proxy vsock/1000 22'"
        " -o ProxyUseFdpass=yes -o ControlMaster=no -o ControlPath=none"
        " alice@hermes-alice -- "
    )
    def guest(cmd):
        return machine.succeed(ssh + f"'bash -lc {cmd!r}'")

    # 1. venv python/pip first on PATH for login shells
    assert "/var/lib/hermes/.venv/bin/python3" in guest("command -v python3")
    assert "/var/lib/hermes/.venv/bin/pip" in guest("command -v pip")
    # 2. pip can install into the venv (offline wheel: pure-python stdlib shim)
    guest("pip install --no-index --no-deps --quiet --dry-run pip")
    # 3. model was NOT seeded (openrouter brain: credentials only)
    machine.succeed(ssh + "'! test -e /var/lib/hermes/.hermes/.model-seeded'")
    # 4. credentials landed in the state .env
    guest("grep -q OPENROUTER_API_KEY /var/lib/hermes/.hermes/.env")
  '';
}
```

- [ ] **Step 3: Register it.** In `flake.nix`, `debugTests` list, append `"hermes-vm"`.

- [ ] **Step 4: Build it** (long; TCG):

Run: `nix build .#debug.x86_64-linux.hermes-vm -L`
Expected: PASS. Iterate on shim/ssh details against the serial log if the vsock route needs adjustment (the exact ssh flags mirror `modules/nixos/hermes/cli.nix` — keep them in sync with whatever that file actually says after the port).

---

### Task 8: Docs

**Files:**
- Create: `docs/hermes.md`

**Interfaces:**
- Consumes: Task 5 option names (verbatim).
- Produces: nothing.

**Depends on:** 5

- [ ] **Step 1: Write `docs/hermes.md`** — condense the architecture header of `modules/nixos/hermes/default.nix` (VM-per-user, vsock shim, dashboard forward, credential path, state vault + WAL invariant, exchange dir) and document the productization contract:
  - `services.hermes-microvm.enable` — default `true` on the desktop profile.
  - `provisionNormalUsers` (default `true`): every uid-declared normal user gets a VM; per-user `users.<n>.enable = false` opts out; uid-less users fail eval with the assertion message (the installer declares `uid = 1000`).
  - Brain rules table: `spaces.openrouter` → credentials only, catalog default on first run; `services.llama-swap` → seed-once local endpoint (`10.0.2.2:<port>`, `gemma4:e4b`); explicit `initialModel` for bespoke endpoints; none → no VMs + warning.
  - Seed-once semantics and the `settings.model` assertion (why: upstream re-merges Nix settings every boot).
  - Upstream caveat: the **dashboard** model selector does not persist under managed mode; TUI `/model` and CLI do.
  - `spaces.openrouter` as the shared key (pi-chat + hermes), renamed from `services.pi-chat.openrouter`.
  - Testing: `checks.hermes-nix-eval` (cheap), `nix build .#debug.x86_64-linux.hermes-vm` (heavy, nested-TCG).

- [ ] **Step 2: Cross-link.** Add a one-line pointer to `docs/hermes.md` from the layout comment in `modules/nixos/hermes/default.nix`.

---

### Task 9: Hyperconfig cutover (repo: `../hyperconfig`)

**Files (all in `../hyperconfig`):**
- Modify: `flake.nix` (drop the `hermes-agent` + `microvm` inputs if nothing else uses microvm — grep first; keep `spaces` input, bump lock)
- Delete: `modules/nixos/hermes/` EXCEPT `site.nix`
- Modify: `modules/nixos/hermes/site.nix` (rewrite, below)
- Modify: `machines/amy/configuration.nix:17` (import path unchanged — verify)

**Interfaces:**
- Consumes: `spaces.nixosModules.hermes`, `services.hermes-microvm.initialModel`, `spaces.openrouter` (Tasks 3-5, via the bumped `spaces` input).
- Produces: nothing.

**Depends on:** 5 (execute only after 6 and 7 are green and the spaces changes are pushed)

- [ ] **Step 1: Bump the spaces input** (or test first with an override):

Run (in `../hyperconfig`): `nix flake update spaces` — for pre-push testing use `nix build … --override-input spaces path:../spaces`.

- [ ] **Step 2: Delete the ported files.**

Run (in `../hyperconfig`): `git rm modules/nixos/hermes/{default,options,vms,guest,guest-python,guest-python-test,host,firewall,cli,scripts,lib,simplex-chat,simplex-chat-package}.nix`
Also remove the `hermes-guest-python` flake check registration in `../hyperconfig/flake.nix` (lines ~204-207, `hermes-guest-python = import ./modules/nixos/hermes/guest-python-test.nix …`).

- [ ] **Step 3: Rewrite `site.nix`.** Keep the clan vars generators (openrouter, telegram) verbatim; replace imports/wiring:

```nix
# Hermes Agent (NousResearch), one microvm per user — the machinery now
# lives in the spaces flake (nixosModules.hermes); this file keeps only
# amy's site wiring: clan-var secrets and the vit.d model seed.
{ config, lib, pkgs, inputs, ... }:
{
  imports = [ inputs.spaces.nixosModules.hermes ];

  # …clan.core.vars.generators.openrouter and .telegram blocks:
  # UNCHANGED from the current file (lines 34-53)…

  # Shared key: same var pi-chat uses.
  spaces.openrouter = {
    enable = true;
    apiKeyFile = config.clan.core.vars.generators.openrouter.files.apikey.path;
  };

  services.hermes-microvm = {
    enable = true;
    # Default brain: qwen3.6 on vit's llama-swap over yggdrasil. Seeded
    # ONCE into a fresh guest config; runtime /model switches persist
    # (amy's existing guest already has a model — the seed never fires).
    initialModel = {
      provider = "custom";
      base_url = "http://vit.d:8012/v1";
      default = "qwen3.6:35b-iq4_xs";
    };
    gpu.enable = true;
    users.grmpf = {
      secretEnv = {
        # secretEnv definition replaces the openrouter default set —
        # OPENROUTER_API_KEY must be re-listed alongside telegram.
        OPENROUTER_API_KEY = config.clan.core.vars.generators.openrouter.files.apikey.path;
        TELEGRAM_BOT_TOKEN = config.clan.core.vars.generators.telegram.files.token.path;
        TELEGRAM_ALLOWED_USERS = config.clan.core.vars.generators.telegram.files.allowed_users.path;
      };
    };
  };
}
```

Notes: `users.grmpf.uid` now defaults from `users.users.grmpf.uid` (declared in amy's config — verify, else keep `uid = 1000;`); `spacesGateway.enable` now defaults from `services.spaces-integrations.enable` on amy — verify amy runs it, else set explicitly; `settings.model`/`extraPlugins`/`simplex` are gone (context_length was a settings.model key — it dies with the pin; the runtime model selector owns it now). `provisionNormalUsers` default-true is fine on amy (grmpf is the only normal user — confirm with `nix eval`).

- [ ] **Step 4: Check remaining input references.**

Run (in `../hyperconfig`): `grep -rn 'hermes-agent\|inputs\.microvm' flake.nix modules/ machines/ | grep -v spaces`
Expected: only removable input declarations; delete `hermes-agent.url`/`follows` lines and, if nothing else imports `microvm`, its input too. Keep `nixos-example.inputs.hermes-agent.follows` consistent (drop or repoint — follow whatever `nixos-example` requires; if it requires the input, keep the input declaration and leave a comment).

- [ ] **Step 5: Build amy.**

Run (in `../hyperconfig`): `nix build .#nixosConfigurations.amy.config.system.build.toplevel --no-link`
Expected: success, no `hermes` eval warnings, rename-free (site.nix uses new paths directly).

---

## Final verification (after all waves)

- Run: `nix flake check` (spaces) — all checks including the two new eval checks pass.
- Run: `nix build .#debug.x86_64-linux.hermes-vm -L` — passes (if not run in Task 7's wave).
- Grep: `grep -rni simplex modules/ checks/ debug/ docs/hermes.md` → nothing.
- Grep: `grep -rn 'pi-chat\.openrouter' modules/ hosts/ checks/` → only the two `mkRenamedOptionModule` lines in `modules/nixos/openrouter.nix`.
