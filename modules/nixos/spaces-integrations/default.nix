# Agent integrations — the NixOS adapter (docs/agent-integrations-design.md §5,
# docs/agent-integrations-poc-plan.md).
#
# Declaring `services.spaces-integrations.integrations.<name> = { … }` emits,
# per integration:
#   - systemd.user.services."spaces-integration-<name>" — the socket-activated,
#     Landlock-confined MCP server (ExecStartPre lowers the per-user policy;
#     ExecStart execs the server through pi-landlock-exec);
#   - systemd.user.sockets."spaces-integration-<name>" — its unix socket at
#     %t/spaces-integration-<name>.sock that the supervisor gateway connects to;
#   - /etc/spaces-integrations/<name>.json — the world-readable definition the
#     gateway / broker / panel read (posture + secret prompts + autoRun).
#
# All lowering lives in ./lib.nix (backend-agnostic); this file only maps that
# neutral data onto the NixOS user-unit / etc surfaces, so a home-manager
# adapter can reuse the same lib. The broker (step 2) owns enable/disable +
# secret provisioning at runtime — using an integration stays rootless (req 10).
# Bundled by modules/nixos/spaces.nix; inert until enabled AND integrations declared.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.services.spaces-integrations;
  integLib = import ./lib.nix { inherit pkgs lib; };

  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  # The policy generator rides as a passthru of the pi-sessiond package (it
  # reuses sandbox.ts's buildLandlockPolicy) but carries no pi closure of its
  # own. pi-landlock-exec is the shared launcher.
  landlockPolicyCli = lib.getExe pkgsSelf.pi-sessiond.landlockPolicy;
  landlockExec = lib.getExe pkgsSelf.pi-landlock-exec;

  secretSubmodule = lib.types.submodule {
    options.description = lib.mkOption {
      type = lib.types.str;
      description = "What this secret is, shown in the settings panel's provisioning form.";
    };
  };

  integrationSubmodule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Human-readable integration name, shown to the user and the agent.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        description = ''
          The integration's MCP server invocation (the ExecStart line, run
          through pi-landlock-exec). Whitespace-split by systemd — no shell.
        '';
      };
      network = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Grant the server outbound IP (AF_INET/AF_INET6). Off => AF_UNIX only,
          so the server can serve its activation socket but reach no network.
          `connectPorts` refines WHICH TCP ports when on.
        '';
      };
      connectPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = ''
          Port-granular TCP egress allowlist (Landlock netPort). Non-empty =>
          only these ports are dialable and every other TCP connect is denied.
          Empty with `network = true` => all ports (coarse). Ignored when
          network is off.
        '';
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf secretSubmodule;
        default = { };
        description = ''
          Secrets the server receives via systemd encrypted credentials
          ($CREDENTIALS_DIRECTORY/<name>). Provisioned through the panel into the
          user's own credstore (host+tpm2); never in the Nix store.
        '';
      };
      autoRun = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Tools the gateway may run without per-call confirmation. Every other
          tool the server exposes stays callable but confirm-per-call. Empty =>
          all-confirm (the safe default). Tool SCHEMAS are discovered at runtime
          from the server, never declared here.
        '';
      };
    };
  };

  built = lib.mapAttrs (
    name: manifest:
    integLib.mkIntegration {
      inherit
        name
        manifest
        landlockPolicyCli
        landlockExec
        ;
      inherit (cfg) memoryHigh;
    }
  ) cfg.integrations;
in
{
  options.services.spaces-integrations = {
    enable = lib.mkEnableOption "agent integrations: per-user, Landlock-confined MCP servers behind the supervisor gateway";

    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "MemoryHigh for each integration's MCP server unit.";
    };

    integrations = lib.mkOption {
      type = lib.types.attrsOf integrationSubmodule;
      default = { };
      description = "Agent integrations to materialise, keyed by short name.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Each user runs their own per-user broker, which seals that user's secrets
    # with `systemd-creds --with-key=host+tpm2` (§5.2) and so needs TPM device
    # access. security.tpm2 provides it — it creates the `tss` group and the
    # /dev/tpmrm0 udev rule. Access is by group membership (the rule carries no
    # uaccess tag), and there is no "all users" group, so grant `tss` to every
    # normal user rather than a single hardcoded account. A VM build of an
    # integrations host also needs a software TPM: set it too, but guarded to
    # where the option exists (a vmVariant / nixosTest node) — never on real
    # hardware, which has a real one.
    security.tpm2.enable = lib.mkDefault true;
    virtualisation = lib.optionalAttrs (options.virtualisation ? tpm) {
      tpm.enable = lib.mkDefault true;
    };
    users.groups.tss.members = builtins.attrNames (
      lib.filterAttrs (_: u: u.isNormalUser) config.users.users
    );

    # The broker runs whenever integrations are enabled (even with none declared
    # yet): it owns enable/disable + secret provisioning over
    # %t/spaces-integrations.sock and starts/stops each integration's socket.
    systemd.user.services =
      (lib.mapAttrs' (_: i: lib.nameValuePair i.unitName i.serviceUnit) built)
      // {
        spaces-integrationd = {
          description = "Spaces integrations broker (enable + secret provisioning over %t/spaces-integrations.sock)";
          wantedBy = [ "default.target" ];
          # systemd splits an unquoted multi-word `Environment=` value on
          # whitespace; the encrypt/systemctl commands carry args, so they ride
          # the `environment` attrset (NixOS quotes it) rather than a raw
          # serviceConfig.Environment list — otherwise the args are dropped.
          environment = {
            SPACES_INTEGRATIOND_SOCKET = "%t/spaces-integrations.sock";
            SPACES_INTEGRATIOND_DEFS_DIR = "/etc/spaces-integrations";
            # Secret path: user-scoped + TPM2-enforced (host+tpm2, never the
            # insecure `auto` fallback, never pure tpm2 which --uid= rejects).
            SPACES_INTEGRATIOND_CREDS_ENCRYPT = "${pkgs.systemd}/bin/systemd-creds encrypt --user --uid=self --with-key=host+tpm2";
            SPACES_INTEGRATIOND_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl --user";
          };
          serviceConfig = {
            Type = "exec";
            ExecStart = lib.getExe pkgsSelf.spaces-integrationd;
            Restart = "on-failure";
            RestartSec = 2;
            StateDirectory = "spaces-integrationd";
            # Trusted (it holds the encrypt path + the socket) but still
            # unprivileged and hardened — it runs as the user, never root.
            NoNewPrivileges = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectClock = true;
            SystemCallArchitectures = "native";
          };
        };
      };

    systemd.user.sockets = lib.mapAttrs' (_: i: lib.nameValuePair i.unitName i.socketUnit) built;

    environment.etc = lib.mapAttrs' (
      name: i: lib.nameValuePair "spaces-integrations/${name}.json" { source = i.definitionFile; }
    ) built;
  };
}
