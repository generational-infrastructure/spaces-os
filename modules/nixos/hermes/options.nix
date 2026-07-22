# Option interface of services.hermes-microvm, the auto-provisioning /
# model-seed derivation, and the assertions that validate it (uids must be
# unique and declared — they derive ports, MAC and firewall identity;
# secretEnv names ride qemu fw_cfg and are length-limited; settings may
# never pin a model — that would clobber the user's runtime choice on
# every boot).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-microvm;
  hostConfig = config;
  orCfg = config.spaces.openrouter;
  llamaOn = config.services.llama-swap.enable or false;
  llamaPort = config.services.llama-swap.port or 8012;
  # Auto-provision scan. Safe to read the MERGED users.users here ONLY
  # because this module tree contributes NOTHING to users.users: qemu
  # runs as the owner, the netfilter identity is a users.GROUPS marker
  # group and linger is a tmpfiles rule (host.nix). Any hermes-owned
  # users.users definition whose names derive from cfg.users would be an
  # unsolvable fixpoint — the module system is strict in every
  # definition's attrNames (N = N0 ∪ f(N)).
  normalUsers = lib.filterAttrs (_: u: u.isNormalUser) config.users.users;
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
        The local llama-swap endpoint when services.llama-swap.enable;
        else null (hermes picks a default at runtime from any configured
        provider — e.g. openrouter's catalog default via the .env key).
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

    settings = mkOption {
      type = types.attrs;
      default = { };
      description = "Hermes settings, passed to the upstream module in every guest.";
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Non-secret env vars for every guest's hermes .env.";
    };

    extraPlugins = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Hermes plugin packages, installed in every guest.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Guest packages on the agent's PATH, in addition to the built-in toolset.";
    };

    pythonPackages = mkOption {
      type = types.functionTo (types.listOf types.package);
      description = "Python libraries preinstalled in every guest's writable venv.";
      default =
        ps: with ps; [
          # math / data (openblas-accelerated), CPU torch (AVX-512), numba JIT
          numpy
          scipy
          sympy
          pandas
          polars
          pyarrow
          duckdb
          matplotlib
          seaborn
          scikit-learn
          statsmodels
          networkx
          numba
          pillow
          tqdm
          # ML
          torch
          transformers
          # research / documents
          pypdf
          openpyxl
          python-docx
          # (nixpkgs `arxiv` currently fails its runtime-deps check; agents
          # can `pip install arxiv` into the venv when needed)
          wikipedia
          # crawling / web
          requests
          httpx
          aiohttp
          beautifulsoup4
          lxml
          html5lib
          feedparser
          trafilatura
          scrapy
          # misc
          pyyaml
          rich
          ipython
        ];
    };

    vcpu = mkOption {
      type = types.int;
      default = 8;
      description = "vCPUs per guest.";
    };

    mem = mkOption {
      type = types.int;
      default = 8192;
      description = "Guest RAM in MiB.";
    };

    gpu = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Vulkan in every guest via QEMU Venus (virtio-gpu-gl on the host
          iGPU's render node). The GPU is time-shared with the host
          desktop, not passed through.
        '';
      };
      hostmem = mkOption {
        type = types.str;
        default = "4G";
        description = ''
          virtio-gpu hostmem: PCI BAR window for mapped host blobs
          (address space, not a RAM reservation).
        '';
      };
    };

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
                defaultText = literalExpression "{ OPENROUTER_API_KEY = spaces.openrouter.apiKeyFile; } when spaces.openrouter is enabled";
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
      description = "users filtered to entries that actually get a VM: enabled with a declared uid. All host/guest wiring iterates this.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Auto-provision: an EMPTY definition per normal user — every value
    # (uid, gateway, openrouter secret) flows from submodule defaults, so
    # explicitly declared users behave identically.
    services.hermes-microvm.users = lib.mkIf cfg.provisionNormalUsers (
      lib.mapAttrs (_: _: { }) normalUsers
    );

    services.hermes-microvm.enabledUsers = lib.filterAttrs (_: u: u.enable && u.uid != null) cfg.users;

    services.hermes-microvm.initialModel = lib.mkDefault (
      if llamaOn then
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

    assertions = [
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
      # host.nix never pins users.users.<u>.uid = ucfg.uid: with the
      # uid defaulting FROM users.users, a pin would be the value cycle
      # x = merge(x, …). Agreement is asserted instead.
      assertion =
        !(ucfg.enable && ucfg.uid != null) || (hostConfig.users.users.${user}.uid or null) == ucfg.uid;
      message = "services.hermes-microvm.users.${user}: uid ${toString ucfg.uid} does not match users.users.${user}.uid — the guest mirrors the host account; declare the same uid on both.";
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
