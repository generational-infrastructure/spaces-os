# Cheap lifecycle contract for the managed stager script
# (modules/nixos/spaces-integrations/default.nix, agent-integrations §10.2).
#
# The stager OWNS /run/spaces-integrations-managed and is CONTENT-AWARE:
#   - removal: switching to a config that drops a profile / integration / user
#     must remove that state, not leave stale managed.json entries or
#     secret-<profile>-<field> copies behind until reboot;
#   - idempotence: re-running the SAME config rewrites nothing (managed.json
#     stays byte-identical, so the broker's content watch never fires on a
#     noop deploy);
#   - rotation: changing ONE secret's content rewrites exactly that staged
#     secret file plus managed.json (whose per-secret sha256 hash changes —
#     the broker's targeted-restart signal), and nothing else.
#
# This check pins all three: it evaluates the systems (like the nix-eval
# checks, via lib/mkMinimalEvalSystem) — v1 stages alice with two demomail profiles
# plus a second user bob; v1rot is v1 with alice's work secret content
# rotated; v2 drops alice's `home` profile and bob entirely — then runs the
# stagers in sequence against one tmp root (SPACES_MANAGED_ROOT, the script's
# test seam; on a real host the env var is never set and the lib.nix literal
# wins) and asserts each transition changes exactly the difference.
#
# Sandbox shape follows spaces-integration-wrapper-shell: the script under
# test runs inside the derivation. Secrets are store-path stubs (the stager
# COPIES secret files at stage time, so any readable path works).
{ pkgs, inputs, ... }:
let
  mkSystem =
    extra:
    inputs.self.lib.mkMinimalEvalSystem {
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
  # Same secret FIELD, different content: the rotation case.
  secretWorkRot = pkgs.writeText "stub-secret-work-rot" "work-secret-rotated";

  profile = address: secret: {
    config.address = address;
    secrets.password.file = "${secret}";
  };

  mkV1 =
    workSecret:
    mkSystem [
      {
        networking.hostName = "stager-lc";
        services.spaces-integrations = {
          enable = true;
          integrations = sampleIntegrations;
        };
        users.users.alice.isNormalUser = true;
        users.users.bob.isNormalUser = true;
        spaces.users.alice.integrations.demomail.profiles = {
          work = profile "a@work.example" workSecret;
          home = profile "a@home.example" secretHome;
        };
        spaces.users.bob.integrations.demomail.profiles.solo = profile "b@solo.example" secretBob;
      }
    ];

  v1 = mkV1 secretWork;
  # v1rot: IDENTICAL config, only the work secret's content rotated. The stager
  # must rewrite exactly that staged copy + managed.json (hash change).
  v1rot = mkV1 secretWorkRot;

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
      pkgs.diffutils
    ];
    stagerV1 = stagerOf v1;
    stagerV1rot = stagerOf v1rot;
    stagerV2 = stagerOf v2;
    inherit secretWork secretWorkRot;
  }
  ''
    set -euo pipefail
    printf '%s\n' "$stagerV1" > v1.sh
    printf '%s\n' "$stagerV1rot" > v1rot.sh
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
    # inode + mtime fingerprint: any rewrite replaces the file (install
    # unlinks) and stamps a fresh mtime — the `sleep 1`s below make mtime
    # changes visible at second granularity.
    snap() { stat -c '%i %Y' "$1"; }
    workHash() { jq -r '.integrations.demomail.profiles.work.secretHashes.password' root/alice/managed.json; }
    ALL_STAGED="root/alice/managed.json root/alice/demomail/managed-config.toml root/alice/demomail/secret-work-password root/alice/demomail/secret-home-password root/bob/managed.json root/bob/demomail/managed-config.toml root/bob/demomail/secret-solo-password"
    snapAll() { for f in $ALL_STAGED; do snap "$f"; done; }

    # ── run 1 (v1): both profiles + bob staged ────────────────────────────────
    ${pkgs.runtimeShell} v1.sh
    [ "$(cat root/alice/demomail/secret-work-password)" = work-secret ] || fail "v1: work secret not staged"
    [ "$(cat root/alice/demomail/secret-home-password)" = home-secret ] || fail "v1: home secret not staged"
    jq -e '.integrations.demomail.profiles | has("work") and has("home")' root/alice/managed.json >/dev/null || fail "v1: managed.json missing a profile"
    grep -F '[demomail.home]' root/alice/demomail/managed-config.toml >/dev/null || fail "v1: toml missing home table"
    [ "$(cat root/bob/demomail/secret-solo-password)" = bob-secret ] || fail "v1: bob secret not staged"
    # per-secret content hash (§10.4): sha256 of the staged secret content
    [ "$(workHash)" = "$(sha256sum "$secretWork" | cut -d ' ' -f1)" ] || fail "v1: work secretHash is not the secret's sha256"

    # ── run 2 (v1 again): identical config → NOTHING rewritten ───────────────
    before="$(snapAll)"
    sleep 1
    ${pkgs.runtimeShell} v1.sh
    after="$(snapAll)"
    [ "$before" = "$after" ] || { echo "before: $before"; echo "after: $after"; fail "idempotence: a second identical run rewrote staged files"; }

    # ── run 3 (v1rot): ONE secret rotated → only it + managed.json move ──────
    hash_before="$(workHash)"
    work_before="$(snap root/alice/demomail/secret-work-password)"
    mj_before="$(snap root/alice/managed.json)"
    rest_before="$(snap root/alice/demomail/managed-config.toml; snap root/alice/demomail/secret-home-password; snap root/bob/managed.json; snap root/bob/demomail/managed-config.toml; snap root/bob/demomail/secret-solo-password)"
    sleep 1
    ${pkgs.runtimeShell} v1rot.sh
    [ "$(cat root/alice/demomail/secret-work-password)" = work-secret-rotated ] || fail "rotation: rotated content not staged"
    [ "$(snap root/alice/demomail/secret-work-password)" != "$work_before" ] || fail "rotation: rotated secret file not rewritten"
    [ "$(snap root/alice/managed.json)" != "$mj_before" ] || fail "rotation: managed.json not rewritten on hash change"
    rest_after="$(snap root/alice/demomail/managed-config.toml; snap root/alice/demomail/secret-home-password; snap root/bob/managed.json; snap root/bob/demomail/managed-config.toml; snap root/bob/demomail/secret-solo-password)"
    [ "$rest_before" = "$rest_after" ] || fail "rotation: unrelated staged files were rewritten"
    [ "$(workHash)" = "$(sha256sum "$secretWorkRot" | cut -d ' ' -f1)" ] || fail "rotation: managed.json hash is not the rotated secret's sha256"
    [ "$(workHash)" != "$hash_before" ] || fail "rotation: managed.json hash did not change"

    # ── run 4 (v2): home profile + user bob removed ───────────────────────────
    ${pkgs.runtimeShell} v2.sh
    # removed profile: its secret copy and config entries must be GONE
    [ ! -e root/alice/demomail/secret-home-password ] || fail "v2: stale home secret survives"
    jq -e '.integrations.demomail.profiles | has("home") | not' root/alice/managed.json >/dev/null || fail "v2: stale home profile in managed.json"
    ! grep -F '[demomail.home]' root/alice/demomail/managed-config.toml || fail "v2: stale home table in managed-config.toml"
    # removed user: the whole per-user dir must be gone
    [ ! -e root/bob ] || fail "v2: stale per-user dir for undeclared user bob"
    # surviving profile: intact and complete (content restored from v1's stub)
    [ "$(cat root/alice/demomail/secret-work-password)" = work-secret ] || fail "v2: surviving work secret damaged"
    jq -e '.integrations.demomail.profiles | has("work")' root/alice/managed.json >/dev/null || fail "v2: surviving profile lost from managed.json"
    grep -F '[demomail.work]' root/alice/demomail/managed-config.toml >/dev/null || fail "v2: surviving toml table lost"

    echo "OK: stager owns the tree — content-aware sync, removals converge"
    touch "$out"
  ''
