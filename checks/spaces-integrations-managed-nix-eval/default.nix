# Cheap nix-eval contract for Nix-managed per-user integration profiles
# (modules/nixos/spaces-users.nix + spaces-integrations/, docs/agent-integrations-
# design.md §10). Pins two halves:
#
#   - validation: the eval-time assertions of §10.1 each fire with their exact
#     message (unknown integration, unknown user, incomplete profile — missing
#     required config field / missing required secret, profiles on a field-less
#     integration), plus a literal secret being a hard type error;
#   - lowering: given a good `spaces.users`, the rendered MCP unit carries the
#     managed directory credential (§10.3), and the root stager materialises the
#     staged tree of §10.2 — the per-user dirs (incl. the always-present
#     per-integration subdirs, even for unmanaged users), managed.json, the
#     managed-config.toml tables, and the copied secret files.
#
# Eval-discipline: no VM, no realized server closure — the stager SCRIPT is
# generated at build time (only `generation` and `file =` values resolve at
# runtime), so the check greps that script text and inspects the rendered
# serviceConfig, never running the stager (it needs root + real users). Grep
# fragments are Nix-computed env vars so their exact bytes are never mangled by
# the build shell.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  mkSystem =
    extra:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [ inputs.self.nixosModules.spaces-integrations ] ++ extra;
    };

  # Nothing here imports lib.nix directly: the assertions are read from the
  # evaluated MODULE (badSystem.config.assertions), so the check pins
  # default.nix's wiring of mkManaged (incl. which user set it validates
  # against), not just lib.nix in isolation.

  # A field-bearing multi-profile integration + a field-less one (signal's shape).
  sampleIntegrations = {
    demomail = {
      description = "Demo mail";
      command = "demo-mail-placeholder";
      network = true;
      multiProfile = true;
      config = {
        address = {
          description = "Email address";
        };
        imap_host = {
          description = "IMAP host";
        };
        display_name = {
          description = "Display name";
          required = false;
        };
      };
      secrets.password = {
        description = "Password";
      };
    };
    # No config/secrets → field-less: only `enable` is allowed per user.
    demosignal = {
      description = "Demo signal";
      command = "demo-signal-placeholder";
    };
  };

  # ── Good system: a complete managed profile + a field-less enable verdict ────
  goodSystem = mkSystem [
    {
      networking.hostName = "managed-on";
      services.spaces-integrations = {
        enable = true;
        integrations = sampleIntegrations;
      };
      users.users.alice.isNormalUser = true;
      # A second normal user with NO Nix opinion: proves the stager still makes
      # her per-integration subdirs (Phase 0.3) but writes her no managed.json.
      users.users.bob.isNormalUser = true;
      spaces.users.alice.integrations = {
        demomail.profiles.work = {
          config = {
            address = "bob@corp.example";
            # file= config: resolved at stage time (never in the store).
            imap_host.file = "/run/secrets/mail-imap-host";
          };
          secrets.password.file = "/run/secrets/mail-work-password";
        };
        # field-less integration: an explicit enable=false verdict, no profiles.
        demosignal.enable = false;
      };
    }
  ];

  demomailSvc = goodSystem.config.systemd.user.services."spaces-integration-demomail";
  demosignalSvc = goodSystem.config.systemd.user.services."spaces-integration-demosignal";
  stagerUnit = goodSystem.config.systemd.services.spaces-integrations-managed-load;

  # ── Bad system: one config per assertion (alice is real; ghost is not) ───────
  badSystem = mkSystem [
    {
      networking.hostName = "managed-bad";
      services.spaces-integrations = {
        enable = true;
        integrations = sampleIntegrations;
      };
      users.users.alice.isNormalUser = true;
      spaces.users = {
        alice.integrations = {
          # unknown integration
          nope.enable = true;
          demomail.profiles = {
            # missing required config field imap_host (secret present)
            no-imap = {
              config.address = "a@b";
              secrets.password.file = "/f";
            };
            # missing required secret password (config complete)
            no-pass.config = {
              address = "a@b";
              imap_host = "h";
            };
          };
          # profiles on a field-less integration
          demosignal.profiles.default = { };
        };
        # unknown user (not in users.users at all)
        ghost.integrations.demomail.enable = true;
        # existing but NON-normal user: passes users.users, must still fail —
        # staging filters to normal users, so accepting root would silently
        # stage nothing.
        root.integrations.demomail.enable = true;
      };
    }
  ];

  failedMessages = map (a: a.message) (
    lib.filter (a: !a.assertion) badSystem.config.assertions
  );
  hasMessage = m: lib.elem m failedMessages;

  # ── A literal secret must be a hard type error (secrets are file-only) ───────
  literalSecretSystem = mkSystem [
    {
      networking.hostName = "managed-lit";
      services.spaces-integrations = {
        enable = true;
        integrations = sampleIntegrations;
      };
      users.users.alice.isNormalUser = true;
      spaces.users.alice.integrations.demomail.profiles.work = {
        config = {
          address = "a@b";
          imap_host = "h";
        };
        secrets.password = "literal-not-allowed";
      };
    }
  ];
  literalSecretEvaluates =
    (builtins.tryEval (
      builtins.deepSeq
        literalSecretSystem.config.spaces.users.alice.integrations.demomail.profiles.work.secrets
        null
    )).success;

  # Exact byte fragments the stager script MUST contain, computed in Nix so the
  # build shell never has to re-escape them.
  wantAll = [
    # tree skeleton (§10.2): root + per-user root + per-integration subdirs.
    # Paths go through $managed_root, whose default is the lib.nix literal —
    # the SPACES_MANAGED_ROOT override exists for the stager-lifecycle check.
    "managed_root=\"\${SPACES_MANAGED_ROOT:-/run/spaces-integrations-managed}\""
    "install -d -m 0755 -o root -g root \"$managed_root\""
    "install -d -m 0500 -o alice -g users \"$managed_root\"/alice/demomail"
    # Phase 0.3 invariant: EVERY declared integration × EVERY user gets a subdir,
    # even a user with no Nix opinion (bob) and an integration alice never configured.
    "\"$managed_root\"/alice/demosignal"
    "install -d -m 0500 -o bob -g users \"$managed_root\"/bob/demomail"
    # managed.json (§10.4): generation bumped at runtime, resolved config
    "gen=\"$(date +%s)\""
    "\"generation\": $generation"
    "\"$managed_root\"/alice/managed.json"
    "\"demomail\": { \"enable\": true, \"profiles\""
    "\"address\": \"bob@corp.example\""
    # file= config resolved at stage time into managed.json (as jq arg $f0)
    "f0=\"$(cat /run/secrets/mail-imap-host)\""
    "--arg f0 \"$f0\""
    "\"imap_host\": $f0"
    # secrets carry only the field-name list, never values
    "\"secrets\": [\"password\"]"
    # a field-less integration carries just its enable verdict
    "\"demosignal\": { \"enable\": false }"
    # managed-config.toml (§10.2): one [integration.profile] table
    "[demomail.work]"
    "address = \"bob@corp.example\""
    # file= config resolved into the toml too (jq @json = a valid basic string)
    "imap_host = %s"
    "jq -rn --arg v \"$f0\""
    "\"$managed_root\"/alice/demomail/managed-config.toml"
    # secret files: COPIED (never symlinked), named secret-<profile>-<field>
    "\"$managed_root\"/alice/demomail/secret-work-password"
    "/run/secrets/mail-work-password"
  ];
  # …and one it must NOT: an unmanaged user gets no managed.json.
  wantNone = [ "\"$managed_root\"/bob/managed.json" ];
in
# ── 1. rendered MCP unit: the managed directory credential (§10.3) ───────────
# field-bearing integration → config credential THEN the managed dir, in order.
assert demomailSvc.serviceConfig.LoadCredential == [
  "config:%S/spaces-integrationd/demomail/config.toml"
  "managed:/run/spaces-integrations-managed/%u/demomail"
];
# field-less integration → only the managed dir (no config credential).
assert demosignalSvc.serviceConfig.LoadCredential == [
  "managed:/run/spaces-integrations-managed/%u/demosignal"
];

# ── 2. each §10.1 assertion fires with its exact message ─────────────────────
assert hasMessage "spaces.users.alice.integrations.nope: unknown integration 'nope' (not in services.spaces-integrations.integrations)";
assert hasMessage "spaces.users.alice.integrations.demomail.profiles.no-imap: missing required config field 'imap_host'";
assert hasMessage "spaces.users.alice.integrations.demomail.profiles.no-pass: missing required secret 'password'";
assert hasMessage "spaces.users.alice.integrations.demosignal: integration 'demosignal' declares no config or secret fields; only 'enable' is allowed, not profiles";
assert hasMessage "spaces.users.ghost: user 'ghost' is not a normal user (spaces.users requires an existing users.users entry with isNormalUser)";
assert hasMessage "spaces.users.root: user 'root' is not a normal user (spaces.users requires an existing users.users entry with isNormalUser)";

# ── 3. a literal secret is a type error (never an accepted store value) ───────
assert !literalSecretEvaluates;

# ── 4. the root stager unit mirrors spaces-secrets-load (root oneshot) ───────
assert stagerUnit.serviceConfig.Type == "oneshot";
assert stagerUnit.serviceConfig.RemainAfterExit;
assert stagerUnit.wantedBy == [ "multi-user.target" ];

pkgs.runCommand "spaces-integrations-managed-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
    stagerScript = stagerUnit.script;
    wantAll = lib.concatStringsSep "\n" wantAll;
    wantNone = lib.concatStringsSep "\n" wantNone;
  }
  ''
    set -euo pipefail
    printf '%s' "$stagerScript" > script.sh
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      grep -F -- "$pat" script.sh >/dev/null || { echo "FAIL: stager missing: $pat" >&2; exit 1; }
    done <<< "$wantAll"
    while IFS= read -r pat; do
      [ -z "$pat" ] && continue
      grep -F -- "$pat" script.sh >/dev/null && { echo "FAIL: stager unexpectedly has: $pat" >&2; exit 1; }
    done <<< "$wantNone"
    echo "OK: spaces.users lowering + assertions pinned"
    touch "$out"
  ''
