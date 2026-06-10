# Cheap nix-eval contract for the loopback executor user service
# (modules/nixos/pi-sessiond-local.nix).
#
# What actually needs pinning here:
#   - the daemon's isolation shape: ProtectHome=tmpfs with the state dir
#     bound back in, untrusted (no SPACES_SESSIOND_TRUSTED), token via
#     LoadCredential from %t, ordered after the token generator;
#   - the env contract main.ts reads: loopback host/port, HOME pointed at
#     the state dir, NO SPACES_SESSIOND_STATE_DIR (the $STATE_DIRECTORY
#     fallback must win), and a systemd-run wrapper that targets the *user*
#     manager (--user) so per-bash transient units land next to the daemon;
#   - the token oneshot owns %t/pi-sessiond-local and survives restarts;
#   - enable=false generates neither unit.
#
# Eval-only: the daemon's ExecStart references the pi-sessiond package
# (which pulls the whole pi build), so it is stripped before anything is
# exported into the runCommand — nothing here may force that build.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  baseModules = [
    {
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      boot.loader.grub.enable = false;
      system.stateVersion = "26.05";
    }
  ];

  mkSystem =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ extra;
    };

  enabledSystem = mkSystem [
    inputs.self.nixosModules.pi-sessiond-local
    {
      networking.hostName = "loopback-on";
      services.pi-sessiond-local.enable = true;
    }
  ];

  disabledSystem = mkSystem [
    inputs.self.nixosModules.pi-sessiond-local
    { networking.hostName = "loopback-off"; }
  ];

  daemon = enabledSystem.config.systemd.user.services.pi-sessiond-local;
  tokenUnit = enabledSystem.config.systemd.user.services.pi-sessiond-local-token;

  # ExecStart is `getExe' package "pi-sessiond"` — exporting it would make
  # the pi build a dependency of this check. Strip it; assert on the rest.
  daemonServiceConfig = builtins.removeAttrs daemon.serviceConfig [ "ExecStart" ];

  disabledServices = disabledSystem.config.systemd.user.services;
in
# The wrapper must force --user: per-bash confinement units have to land in
# the user manager, not pid 1. writeShellScript is trivially buildable at
# eval, so read its content here rather than dragging shell parsing into
# the runCommand below.
assert lib.hasInfix "--user" (builtins.readFile daemon.environment.SPACES_SESSIOND_SYSTEMD_RUN);
pkgs.runCommand "pi-sessiond-local-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    daemonServiceConfig = builtins.toJSON daemonServiceConfig;
    daemonEnvironment = builtins.toJSON daemon.environment;
    daemonRequires = builtins.toJSON daemon.requires;
    daemonAfter = builtins.toJSON daemon.after;
    tokenServiceConfig = builtins.toJSON tokenUnit.serviceConfig;
    disabledHasDaemon = if (disabledServices.pi-sessiond-local or null) == null then "no" else "yes";
    disabledHasToken =
      if (disabledServices.pi-sessiond-local-token or null) == null then "no" else "yes";
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    sc()   { jq -e "$1" <<<"$daemonServiceConfig" >/dev/null || fail "daemon serviceConfig: $1"; }
    env_() { jq -e "$1" <<<"$daemonEnvironment"   >/dev/null || fail "daemon environment: $1"; }
    tok()  { jq -e "$1" <<<"$tokenServiceConfig"  >/dev/null || fail "token serviceConfig: $1"; }

    # ── 1. Daemon sandbox shape ─────────────────────────────────────
    sc '.ProtectHome == "tmpfs"'
    sc '.StateDirectory == "pi-sessiond-local"'
    sc '.LoadCredential == ["token:%t/pi-sessiond-local/token"]'
    # State dir back through the ProtectHome tmpfs, plus the user
    # manager's IPC endpoints (%t/systemd private socket + %t/bus) —
    # ProtectHome=tmpfs empties /run/user too, and without these the
    # daemon's `systemd-run --user` bash spawner cannot reach the
    # manager. Sediment DB bind comes from memory.enable (default on).
    sc '.BindPaths == ["%S/pi-sessiond-local", "%t/systemd", "%t/bus", "%h/.local/state/spaces/pi/sediment"]'

    # ── 1b. Memory parity (sediment runs in-process, daemon ns) ─────
    env_ '.SEDIMENT_DB == "%h/.local/state/spaces/pi/sediment/data"'
    env_ '.HF_HOME | startswith("/nix/store/")'
    env_ '.SPACES_SESSIOND_PI_EXTENSIONS | contains("memory")'

    # Ordered after (and hard-required on) the token generator.
    jq -e 'index("pi-sessiond-local-token.service") != null' <<<"$daemonRequires" >/dev/null \
      || fail "daemon must Requires= pi-sessiond-local-token.service"
    jq -e 'index("pi-sessiond-local-token.service") != null' <<<"$daemonAfter" >/dev/null \
      || fail "daemon must be After= pi-sessiond-local-token.service"

    # ── 2. Daemon env contract (what main.ts reads) ─────────────────
    env_ '.SPACES_SESSIOND_HOST == "127.0.0.1"'
    env_ '.SPACES_SESSIOND_PORT == "8768"'
    # Untrusted default = ProtectHome for every bash command.
    env_ 'has("SPACES_SESSIOND_TRUSTED") | not'
    # $STATE_DIRECTORY (from StateDirectory= above) must win.
    env_ 'has("SPACES_SESSIOND_STATE_DIR") | not'
    env_ '.HOME == "%S/pi-sessiond-local"'
    # The --user content check happened at eval; here just pin that the
    # wrapper is a real store path, not a bare "systemd-run".
    env_ '.SPACES_SESSIOND_SYSTEMD_RUN | startswith("/nix/store/")'

    # ── 3. Token oneshot owns the runtime dir and stays "active" ────
    tok '.RuntimeDirectory == "pi-sessiond-local"'
    tok '.RemainAfterExit == true'

    # ── 4. enable = false generates neither unit ────────────────────
    [ "$disabledHasDaemon" = "no" ] || fail "disabled module still declares the daemon unit"
    [ "$disabledHasToken"  = "no" ] || fail "disabled module still declares the token unit"

    touch "$out"
  ''
