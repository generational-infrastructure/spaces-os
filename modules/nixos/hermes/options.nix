# Option interface of services.hermes-microvm, the auto-provisioning /
# model-seed derivation, and the assertions that validate it (per-VM
# identity is a hash of the USERNAME — lib.nix identityHash; derived
# CID/port and dashboardPort collisions are asserted;
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
  hlib = import ./lib.nix { inherit lib; };
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
        Auto-provision a VM for every isNormalUser. Opt out per user via
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
          { name, ... }:
          {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether this user gets a VM.";
              };
              dashboardPort = mkOption {
                type = types.port;
                default = 22100 + lib.mod (hlib.identityHash name) 1000;
                defaultText = literalExpression ''22100 + lib.mod (identityHash name) 1000'';
                description = ''
                  Host 127.0.0.1 port forwarded to the guest dashboard
                  (hash-derived; override on the rare window collision —
                  the eval assertion names the colliding users).
                '';
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
              spacesGateway.enable = mkOption {
                type = types.bool;
                default = hostConfig.services.spaces-integrations.enable or false;
                defaultText = literalExpression "config.services.spaces-integrations.enable";
                description = ''
                  Bridge the user's spaces integration gateway (the fixed
                  per-user socket /run/user/<uid>/spaces-integration-gateway.sock,
                  uid resolved at runtime) into the VM.
                '';
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
      description = "users filtered to enabled entries. All host/guest wiring iterates this.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Auto-provision: an EMPTY definition per normal user — every value
    # (ports, gateway, openrouter secret) flows from submodule defaults, so
    # explicitly declared users behave identically.
    services.hermes-microvm.users = lib.mkIf cfg.provisionNormalUsers (
      lib.mapAttrs (_: _: { }) normalUsers
    );

    services.hermes-microvm.enabledUsers = lib.filterAttrs (_: u: u.enable) cfg.users;

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
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: ucfg:
        # sha256(username) collisions are ~1 in 4e9, but CID, MAC and
        # the bridge port all derive from the hash — never let one
        # through. Asserted on the derived values: the mod-reductions
        # in cidFor/spacesVsockPort wrap, so distinct hashes can alias
        # (a full-hash/MAC collision implies both, so it is covered).
        map
          (fn: {
            assertion =
              !ucfg.enable
              || lib.count (u: hlib.${fn} u == hlib.${fn} user) (
                lib.attrNames (lib.filterAttrs (_: u: u.enable) cfg.users)
              ) == 1;
            message = "services.hermes-microvm: ${fn} collision on ${user} — rename one of the colliding users or disable one VM (services.hermes-microvm.users.<name>.enable = false).";
          })
          [
            "cidFor"
            "spacesVsockPort"
          ]
      ) cfg.users
    )
    ++ lib.mapAttrsToList (user: ucfg: {
      assertion =
        !ucfg.enable
        || lib.count (u: u.enable && u.dashboardPort == ucfg.dashboardPort) (lib.attrValues cfg.users)
          == 1;
      message = "services.hermes-microvm: duplicate dashboardPort ${toString ucfg.dashboardPort} (${user}) — the hash-derived default collided in its 1000-port window; set services.hermes-microvm.users.<name>.dashboardPort explicitly on one of them.";
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
