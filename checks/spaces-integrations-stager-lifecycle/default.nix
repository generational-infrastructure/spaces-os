# Cheap lifecycle contract for the managed stager script
# (modules/nixos/spaces-integrations/default.nix, agent-integrations §10.2).
#
# The stager OWNS /run/spaces-integrations-managed: switching to a generation
# that drops a profile / integration / user must remove that state, not leave
# stale managed.json entries or secret-<profile>-<field> copies behind until
# reboot. This check pins exactly that: it evaluates TWO systems (like the
# nix-eval checks, via lib/mkEvalSystem) — v1 stages alice with two demomail
# profiles plus a second user bob; v2 drops alice's `home` profile and bob
# entirely — then runs v1's stager followed by v2's against one tmp root
# (SPACES_MANAGED_ROOT, the script's test seam; on a real host the env var is
# never set and the lib.nix literal wins) and asserts the difference is gone
# while the surviving profile is intact.
#
# Sandbox shape follows spaces-integration-wrapper-shell: the script under
# test runs inside the derivation. Secrets are store-path stubs (the stager
# COPIES secret files at stage time, so any readable path works).
{ pkgs, inputs, ... }:
let
  mkSystem =
    extra:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [ inputs.self.nixosModules.spaces-integrations ] ++ extra;
    };

  sampleIntegrations = {
    demomail = {
      description = "Demo mail";
      command = "demo-mail-placeholder";
      network = true;
      multiProfile = true;
      config.address.description = "Email address";
      secrets.password.description = "Password";
    };
  };

  secretWork = pkgs.writeText "stub-secret-work" "work-secret";
  secretHome = pkgs.writeText "stub-secret-home" "home-secret";
  secretBob = pkgs.writeText "stub-secret-bob" "bob-secret";

  profile = address: secret: {
    config.address = address;
    secrets.password.file = "${secret}";
  };

  v1 = mkSystem [
    {
      networking.hostName = "stager-lc";
      services.spaces-integrations = {
        enable = true;
        integrations = sampleIntegrations;
      };
      users.users.alice.isNormalUser = true;
      users.users.bob.isNormalUser = true;
      spaces.users.alice.integrations.demomail.profiles = {
        work = profile "a@work.example" secretWork;
        home = profile "a@home.example" secretHome;
      };
      spaces.users.bob.integrations.demomail.profiles.solo = profile "b@solo.example" secretBob;
    }
  ];

  # v2: alice's `home` profile dropped AND bob gone entirely. The stager must
  # remove exactly the difference.
  v2 = mkSystem [
    {
      networking.hostName = "stager-lc";
      services.spaces-integrations = {
        enable = true;
        integrations = sampleIntegrations;
      };
      users.users.alice.isNormalUser = true;
      spaces.users.alice.integrations.demomail.profiles.work = profile "a@work.example" secretWork;
    }
  ];

  stagerOf = sys: sys.config.systemd.services.spaces-integrations-managed-load.script;
in
pkgs.runCommand "spaces-integrations-stager-lifecycle"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.gnugrep
      pkgs.coreutils
    ];
    stagerV1 = stagerOf v1;
    stagerV2 = stagerOf v2;
  }
  ''
    set -euo pipefail
    printf '%s\n' "$stagerV1" > v1.sh
    printf '%s\n' "$stagerV2" > v2.sh

    # The scripts run `install -o <user> -g <group> -m 0500/0400`: chown is
    # impossible (and the users don't exist) in the sandbox, and the read-only
    # modes would lock the unprivileged builder out of its own tree — a
    # root-only concern, not the lifecycle under test. Shim install to drop
    # ownership/mode flags.
    mkdir -p shim
    cat > shim/install <<'EOF'
    #!${pkgs.runtimeShell}
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|-g|-m) shift 2 ;;
        *) args+=("$1"); shift ;;
      esac
    done
    exec ${pkgs.coreutils}/bin/install "''${args[@]}"
    EOF
    chmod +x shim/install
    export PATH="$PWD/shim:$PATH"

    export SPACES_MANAGED_ROOT="$PWD/root"

    fail() { echo "FAIL: $1" >&2; exit 1; }

    # ── generation 1: both profiles + bob staged ─────────────────────────────
    ${pkgs.runtimeShell} v1.sh
    [ "$(cat root/alice/demomail/secret-work-password)" = work-secret ] || fail "v1: work secret not staged"
    [ "$(cat root/alice/demomail/secret-home-password)" = home-secret ] || fail "v1: home secret not staged"
    jq -e '.integrations.demomail.profiles | has("work") and has("home")' root/alice/managed.json >/dev/null || fail "v1: managed.json missing a profile"
    grep -F '[demomail.home]' root/alice/demomail/managed-config.toml >/dev/null || fail "v1: toml missing home table"
    [ "$(cat root/bob/demomail/secret-solo-password)" = bob-secret ] || fail "v1: bob secret not staged"

    # ── generation 2: home profile + user bob removed ─────────────────────────
    ${pkgs.runtimeShell} v2.sh
    # removed profile: its secret copy and config entries must be GONE
    [ ! -e root/alice/demomail/secret-home-password ] || fail "v2: stale home secret survives"
    jq -e '.integrations.demomail.profiles | has("home") | not' root/alice/managed.json >/dev/null || fail "v2: stale home profile in managed.json"
    ! grep -F '[demomail.home]' root/alice/demomail/managed-config.toml || fail "v2: stale home table in managed-config.toml"
    # removed user: the whole per-user dir must be gone
    [ ! -e root/bob ] || fail "v2: stale per-user dir for undeclared user bob"
    # surviving profile: intact and complete
    [ "$(cat root/alice/demomail/secret-work-password)" = work-secret ] || fail "v2: surviving work secret damaged"
    jq -e '.integrations.demomail.profiles | has("work")' root/alice/managed.json >/dev/null || fail "v2: surviving profile lost from managed.json"
    grep -F '[demomail.work]' root/alice/demomail/managed-config.toml >/dev/null || fail "v2: surviving toml table lost"

    echo "OK: stager owns the tree — removals converge"
    touch "$out"
  ''
