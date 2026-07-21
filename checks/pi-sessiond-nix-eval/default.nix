# Cheap nix-eval contract for the loopback executor user service
# (modules/nixos/pi-sessiond/).
#
# What actually needs pinning here:
#   - the daemon's isolation shape: ProtectHome=tmpfs with the state dir
#     bound back in, no removed SPACES_SESSIOND_TRUSTED knob, token via
#     LoadCredential from %t, ordered after the token generator;
#   - the env contract main.ts reads: loopback host/port, HOME pointed at
#     the state dir, NO SPACES_SESSIOND_STATE_DIR (the $STATE_DIRECTORY
#     fallback must win), and a systemd-run wrapper that targets the *user*
#     manager (--user) so the per-session pi units land next to the daemon;
#   - the token oneshot owns %t/pi-sessiond and survives restarts;
#   - enable=false generates neither unit.
#
# Eval-only: the daemon's ExecStart references the pi-sessiond package
# (which pulls the whole pi build), so it is stripped before anything is
# exported into the runCommand — nothing here may force that build.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  # Minimal eval (lib/default.nix:mkMinimalEvalSystem): this check only reads
  # systemd.user.* and services.pi-{sessiond,chat}.*, all in the base.
  mkSystem =
    extra:
    inputs.self.lib.mkMinimalEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = extra;
    };

  enabledSystem = mkSystem [
    inputs.self.nixosModules.pi-sessiond
    {
      networking.hostName = "loopback-on";
      services.pi-sessiond.enable = true;
    }
  ];

  disabledSystem = mkSystem [
    inputs.self.nixosModules.pi-sessiond
    { networking.hostName = "loopback-off"; }
  ];

  # A system importing ONLY the pi-chat module: enabling the panel must
  # bring the loopback executor with it (localExecutor.enable defaults
  # true) — the panel has no other execution path. Guards against the
  # default regressing to opt-in, which would ship a panel that can
  # never run a session unless a bundle (spaces.nix) re-enables it.
  panelOnlySystem = mkSystem [
    inputs.self.nixosModules.pi-chat
    {
      networking.hostName = "panel-only";
      services.pi-chat.enable = true;
    }
  ];
  panelDaemon = panelOnlySystem.config.systemd.user.services.pi-sessiond or null;

  daemon = enabledSystem.config.systemd.user.services.pi-sessiond;
  tokenUnit = enabledSystem.config.systemd.user.services.pi-sessiond-token;

  # ExecStart is `getExe' package "pi-sessiond"` — exporting it would make
  # the pi build a dependency of this check. Strip it; assert on the rest.
  daemonServiceConfig = builtins.removeAttrs daemon.serviceConfig [ "ExecStart" ];

  disabledServices = disabledSystem.config.systemd.user.services;
in
# PI_BIN points at the pi build the supervisor spawns as the rpc child; assert
# its shape at eval (a string match never realizes the path, keeping this check
# off the pi build — same reason ExecStart is stripped below).
assert lib.hasSuffix "/bin/pi" daemon.environment.SPACES_SESSIOND_PI_BIN;
# The --user wrapper and the settings.json `memory` extension are content
# assertions grepped in the runCommand: reading either file here would be
# import-from-derivation, disabled repo-wide.
# Landlock is the desktop executor's only sandbox: the daemon always points each
# pi child at landlock-exec. A string match never realizes the Rust build
# (same discipline as PI_BIN / ExecStart).
assert lib.hasSuffix "/bin/landlock-exec" daemon.environment.SPACES_SESSIOND_LANDLOCK_EXEC;
pkgs.runCommand "pi-sessiond-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    daemonServiceConfig = builtins.toJSON daemonServiceConfig;
    daemonEnvironment = builtins.toJSON (
      builtins.removeAttrs daemon.environment [ "SPACES_SESSIOND_PI_BIN" ]
    );
    # Grepped below; already inputs via daemonEnvironment, so naming is free.
    systemdRunWrapper = daemon.environment.SPACES_SESSIOND_SYSTEMD_RUN;
    piSettings = daemon.environment.SPACES_SESSIOND_PI_SETTINGS;
    daemonRequires = builtins.toJSON daemon.requires;
    daemonAfter = builtins.toJSON daemon.after;
    tokenServiceConfig = builtins.toJSON tokenUnit.serviceConfig;
    disabledHasDaemon = if (disabledServices.pi-sessiond or null) == null then "no" else "yes";
    disabledHasToken = if (disabledServices.pi-sessiond-token or null) == null then "no" else "yes";
    panelOnlyDaemonEnabled = if panelOnlySystem.config.services.pi-sessiond.enable then "yes" else "no";
    panelOnlyHasDaemonUnit = if panelDaemon == null then "no" else "yes";
    # The forwarding contract is engaged, not just the enable bit: the
    # daemon's per-session env carries the skill-config socket only when
    # pi-chat's localExecutor wiring populated sessionEnv.
    panelOnlySessionEnv =
      if panelDaemon == null then "{}" else panelDaemon.environment.SPACES_SESSIOND_SESSION_ENV;
    panelOnlyDefaultExecutor = panelOnlySystem.config.services.pi-chat.defaultExecutor;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    sc()   { jq -e "$1" <<<"$daemonServiceConfig" >/dev/null || fail "daemon serviceConfig: $1"; }
    env_() { jq -e "$1" <<<"$daemonEnvironment"   >/dev/null || fail "daemon environment: $1"; }
    tok()  { jq -e "$1" <<<"$tokenServiceConfig"  >/dev/null || fail "token serviceConfig: $1"; }

    # ── 1. Daemon sandbox shape ─────────────────────────────────────
    sc '.ProtectHome == "tmpfs"'
    sc '.StateDirectory == "pi-sessiond"'
    sc '.LoadCredential == ["token:%t/pi-sessiond/token"]'
    # State dir back through the ProtectHome tmpfs, plus the user
    # manager's IPC endpoints (%t/systemd private socket + %t/bus) —
    # ProtectHome=tmpfs empties /run/user too, and without these the
    # daemon's `systemd-run --user` bash spawner cannot reach the
    # manager. Sediment DB bind comes from memory.enable (default on).
    sc '.BindPaths == ["%S/pi-sessiond", "%t/systemd", "%t/bus", "%h/.local/state/spaces/pi/sediment"]'

    # ── 1b. Memory parity: sediment runs in the child, which inherits the
    # supervisor's SEDIMENT_DB/HF_HOME; the extension itself loads via
    # settings.json (grepped below). ────────────────────────────────
    env_ '.SEDIMENT_DB == "%h/.local/state/spaces/pi/sediment/data"'
    env_ '.HF_HOME | startswith("/nix/store/")'
    # Memory loads inside the child via settings.json, not a daemon env var —
    # the generated settings must still list the sediment extension.
    grep -q memory "$piSettings" || fail "settings.json does not list the memory extension"

    # Ordered after (and hard-required on) the token generator.
    jq -e 'index("pi-sessiond-token.service") != null' <<<"$daemonRequires" >/dev/null \
      || fail "daemon must Requires= pi-sessiond-token.service"
    jq -e 'index("pi-sessiond-token.service") != null' <<<"$daemonAfter" >/dev/null \
      || fail "daemon must be After= pi-sessiond-token.service"

    # ── 2. Daemon env contract (what main.ts reads) ─────────────────
    env_ '.SPACES_SESSIOND_HOST == "127.0.0.1"'
    env_ '.SPACES_SESSIOND_PORT == "8768"'
    # The removed SPACES_SESSIOND_TRUSTED knob must stay gone.
    env_ 'has("SPACES_SESSIOND_TRUSTED") | not'
    # $STATE_DIRECTORY (from StateDirectory= above) must win.
    env_ 'has("SPACES_SESSIOND_STATE_DIR") | not'
    env_ '.HOME == "%S/pi-sessiond"'
    # The wrapper must force --user so per-session confinement units land in the
    # user manager, not pid 1. Pin a real store path, then grep for the flag.
    env_ '.SPACES_SESSIOND_SYSTEMD_RUN | startswith("/nix/store/")'
    grep -q -- --user "$systemdRunWrapper" || fail "systemd-run wrapper does not force --user"

    # ── 3. Token oneshot owns the runtime dir and stays "active" ────
    tok '.RuntimeDirectory == "pi-sessiond"'
    tok '.RemainAfterExit == true'

    # ── 4. enable = false generates neither unit ────────────────────
    [ "$disabledHasDaemon" = "no" ] || fail "disabled module still declares the daemon unit"
    [ "$disabledHasToken"  = "no" ] || fail "disabled module still declares the token unit"

    # ── 5. pi-chat alone brings the loopback executor (default-on) ──
    [ "$panelOnlyDaemonEnabled" = "yes" ] \
      || fail "pi-chat-only import left services.pi-sessiond.enable false"
    [ "$panelOnlyHasDaemonUnit" = "yes" ] \
      || fail "pi-chat-only import generated no pi-sessiond unit"
    jq -e '.SKILL_CONFIG_SOCKET == "%t/spaces-skill-config.sock"' <<<"$panelOnlySessionEnv" >/dev/null \
      || fail "pi-chat-only import did not forward the skill env into the daemon"
    [ "$panelOnlyDefaultExecutor" = "host" ] \
      || fail "pi-chat-only import did not default-pin sessions at the loopback executor"

    touch "$out"
  ''
