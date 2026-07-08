# Contract for the sandboxed setup channel + GUI lifecycle wiring the
# spaces-integrations module now ships (agent-integrations design §5.5, the
# default-integrations + GUI-only-lifecycle work).
#
# Pins, all as pure nix-eval (no server build):
#   - the twin setup unit: for signal (`setup != null`) lib.nix emits a
#     spaces-integration-signal-setup service whose serviceConfig is IDENTICAL
#     to the main server's minus ExecStart (same sandbox), and a setup socket at
#     %t/spaces-integration-signal-setup.sock (SocketMode 0600, no wantedBy);
#   - the main socket carries Wants=/After= each unit in the manifest's
#     extraServices;
#   - the definition JSON the panel/broker read gains `setup` (bool) and
#     `extraServices` (verbatim list);
#   - an integration WITHOUT setup (github) emits no twin, definition.setup is
#     false, definition.extraServices is [], and its socket has no Wants/After;
#   - the module emits the twin service + socket into systemd.user.{services,
#     sockets} when enabled, and injects PartOf=spaces-integration-signal.socket
#     onto every extraServices unit (spaces-signal-cli/bridge);
#   - mkDefault discipline: a host overriding ONE sub-option (github.autoRun)
#     keeps every other default (network, connectPorts) intact.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  integLib = import ../../modules/nixos/spaces-integrations/lib.nix {
    inherit pkgs lib;
    inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond) seccompDenylist;
  };

  mkSystem =
    extra:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = extra;
    };

  # Defaults come with the module; enabling it materialises their units.
  defsSystem = mkSystem [
    inputs.self.nixosModules.spaces-integrations
    {
      networking.hostName = "integ-setup-fixture";
      services.spaces-integrations.enable = true;
    }
  ];
  inherit (defsSystem.config.services.spaces-integrations) integrations;

  integOf =
    name:
    integLib.mkIntegration {
      inherit name;
      manifest = integrations.${name};
      landlockPolicyCli = "unused";
      landlockExec = "unused";
    };

  signal = integOf "signal";
  github = integOf "github";

  extraServices = [
    "spaces-signal-cli.service"
    "spaces-signal-bridge.service"
  ];

  # Twin setup serviceConfig must equal the main server's minus ExecStart — same
  # Landlock/seccomp/credentials/Environment/MemoryHigh sandbox, only the command
  # differs. Strip ExecStart before comparing (also keeps the real integration-
  # signal-setup store path out of the comparison).
  signalMainCfg = builtins.removeAttrs signal.serviceUnit.serviceConfig [ "ExecStart" ];
  signalSetupCfg = builtins.removeAttrs signal.setupServiceUnit.serviceConfig [ "ExecStart" ];

  # PartOf injection lands on the REAL signal-cli units, so import that module.
  partOfSystem = mkSystem [
    inputs.self.nixosModules.spaces-integrations
    inputs.self.nixosModules.signal-cli
    {
      networking.hostName = "integ-partof-fixture";
      services.spaces-integrations.enable = true;
      services.spaces-signal.enable = true;
    }
  ];
  partOf = name: partOfSystem.config.systemd.user.services.${name}.unitConfig.PartOf or [ ];

  # mkDefault discipline: override ONE sub-option, the rest of github's defaults
  # must survive.
  overrideSystem = mkSystem [
    inputs.self.nixosModules.spaces-integrations
    {
      networking.hostName = "integ-mkdefault-fixture";
      services.spaces-integrations.enable = true;
      services.spaces-integrations.integrations.github.autoRun = [ "custom_tool" ];
    }
  ];
  ovGithub = overrideSystem.config.services.spaces-integrations.integrations.github;
in
# ── signal: twin setup unit ──────────────────────────────────────────────────
assert signal.hasSetup;
assert signal.setupServiceUnit != null;
assert signal.setupSocketUnit != null;
# Identical sandbox to the main server, only ExecStart differs.
assert signalMainCfg == signalSetupCfg;
assert
  signal.serviceUnit.serviceConfig.ExecStart != signal.setupServiceUnit.serviceConfig.ExecStart;
# Setup socket path + posture.
assert
  signal.setupSocketUnit.socketConfig.ListenStream == "%t/spaces-integration-signal-setup.sock";
assert signal.setupSocketUnit.socketConfig.SocketMode == "0600";
assert !(signal.setupSocketUnit ? wantedBy);
# ── signal: main socket Wants/After on extraServices ─────────────────────────
assert signal.socketUnit.wants == extraServices;
assert signal.socketUnit.after == extraServices;
# ── signal: definition JSON carries setup + extraServices ────────────────────
assert signal.definition.setup == true;
assert signal.definition.extraServices == extraServices;
# ── github: no setup, no extra services, no socket Wants/After ───────────────
assert !github.hasSetup;
assert github.setupServiceUnit == null;
assert github.setupSocketUnit == null;
assert github.definition.setup == false;
assert github.definition.extraServices == [ ];
assert !(github.socketUnit ? wants);
assert !(github.socketUnit ? after);
# ── module emits the twin units when enabled ─────────────────────────────────
assert defsSystem.config.systemd.user.services ? "spaces-integration-signal-setup";
assert defsSystem.config.systemd.user.sockets ? "spaces-integration-signal-setup";
# github has no setup, so no twin.
assert !(defsSystem.config.systemd.user.services ? "spaces-integration-github-setup");
assert !(defsSystem.config.systemd.user.sockets ? "spaces-integration-github-setup");
# ── PartOf injected onto every extraServices unit ────────────────────────────
assert lib.elem "spaces-integration-signal.socket" (partOf "spaces-signal-cli");
assert lib.elem "spaces-integration-signal.socket" (partOf "spaces-signal-bridge");
# ── mkDefault discipline: override one field, keep the rest ──────────────────
assert ovGithub.autoRun == [ "custom_tool" ];
assert ovGithub.network == true;
assert ovGithub.connectPorts == [ 443 ];
pkgs.runCommand "spaces-integrations-setup-nix-eval-test" { } ''
  echo "setup twin units + socket Wants/After + PartOf injection + definition setup/extraServices + mkDefault discipline OK"
  touch "$out"
''
