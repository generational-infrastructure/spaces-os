# llama-swap service with llama-cpp built for GPU acceleration.
#
# Wraps the upstream services.llama-swap NixOS module, providing:
# - llama-cpp with Vulkan + BLAS (+ CUDA when hardware.nvidia.enabled)
# - Sensible defaults (listen address, health check timeout, log routing)
# - Unix socket proxy for rootless Docker containers
# - A sleep.target hook to free GPU VRAM across suspend/resume cycles
# - XDG cache fix for llama-cpp model downloads
{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.services.llama-swap;
  nvidiaEnabled = config.hardware.nvidia.enabled or false;

  llama-cpp-accelerated = pkgs.llama-cpp.override {
    cudaSupport = nvidiaEnabled;
    vulkanSupport = true;
    blasSupport = true;
    rocmSupport = false;
    metalSupport = false;
  };

  llama-server = lib.getExe' cfg.llama-server-package "llama-server";

  qwen25-05b-gguf = builtins.fetchurl {
    url = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf";
    sha256 = "sha256-dKTajJ/bzRW9H20B1iFBDTHG/ACYb162h4JOe5PXqds=";
  };

  gemma4-e2b-gguf = builtins.fetchurl {
    url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q6_K.gguf";
    sha256 = "sha256-s2gk8Tv5+rKRDLe0KCpNc7E3me5BJtTsJBMJzmnA54M=";
  };

  gemma4-e4b-gguf = builtins.fetchurl {
    url = "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q6_K.gguf";
    sha256 = "sha256-Pb9j4ivoM9DmhPJrNtRUSPXyBvDnpsrGtKqeDPTJzOg=";
  };

  settingsFormat = pkgs.formats.yaml { };

  # Minimal valid baseline seeded into externalConfigFile the first time the
  # service starts (only when the file is absent). Carries the health-check
  # default and, when a shared key is provisioned, the apiKeys requirement —
  # so an externally managed endpoint starts out authenticated, not open.
  # No models: those are the user's to add at runtime.
  externalSeed = settingsFormat.generate "llama-swap-seed.yaml" {
    healthCheckTimeout = 3600;
    logToStdout = "both";
    apiKeys = lib.optionals (cfg.apiKeyEnvFile != null) [ "\${env.LLAMA_SWAP_API_KEY}" ];
    models = { };
  };
in
{
  options.services.llama-swap = {
    llama-server-package = lib.mkOption {
      type = lib.types.package;
      default = llama-cpp-accelerated;
      defaultText = lib.literalExpression "pkgs.llama-cpp with Vulkan + BLAS (+ CUDA when NVIDIA enabled)";
      description = "llama-cpp package providing llama-server.";
    };

    modelExtraArgs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "qwen2.5:0.5b" = "--temp 0 --seed 42";
      };
      description = "Per-model extra llama-server flags appended to its cmd.";
    };

    apiKeyEnvFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/llama-swap.env";
      description = ''
        Path to a systemd `EnvironmentFile` defining `LLAMA_SWAP_API_KEY=<key>`.
        When set, llama-swap requires that key (`Authorization: Bearer`,
        `x-api-key`, or HTTP Basic) on its inference and `/api` endpoints. The
        file is read at runtime by systemd — the key never enters the
        world-readable Nix store. `null` (the default) leaves llama-swap in its
        default-allow mode (no authentication).
      '';
    };

    externalConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/llama-swap/config.yaml";
      description = ''
        Source the model catalog from a writable file managed outside Nix,
        instead of the bundled, store-pinned model set.

        `null` (the default) ships the in-module catalog (qwen2.5 / gemma4),
        fetching each GGUF into the store — fully reproducible, but every
        served model is part of the system closure.

        Set to a path and llama-swap loads that file directly and runs with
        `-watch-config`, reloading on change. The bundled catalog is dropped
        so its GGUFs never enter the closure; models are added/removed at
        runtime by editing the file (and dropping the GGUFs anywhere the
        service can read), no rebuild. The path must live outside `/home` and
        `/root` (the unit runs with `ProtectHome`); it is readable there but,
        as seeded, writable only by root. The file is seeded with a minimal
        valid baseline (health-check + the shared-key requirement when
        `apiKeyEnvFile` is set) on first start if it does not yet exist —
        keep that `apiKeys` line, or the endpoint becomes unauthenticated.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    hardware.graphics.enable = lib.mkDefault true;

    services.llama-swap =
      let
        modelArgs = id: lib.optionalString (cfg.modelExtraArgs ? ${id}) " ${cfg.modelExtraArgs.${id}}";
      in
      {
        listenAddress = "0.0.0.0";
        # Plain assignment (priority 100): beats upstream's option
        # default of 8080 (priority 1500). Users override with
        # `lib.mkForce <port>` if they need something other than 8012.
        port = 8012;
        settings = {
          healthCheckTimeout = 3600;
          logToStdout = "both";
          # Require the shared key when one is provisioned (apiKeyEnvFile). The
          # literal `''${env.LLAMA_SWAP_API_KEY}` is resolved by llama-swap from
          # its process environment at startup, so the secret stays out of the
          # store-rendered config.yaml. Empty list = upstream default-allow.
          apiKeys = lib.optionals (cfg.apiKeyEnvFile != null) [ "\${env.LLAMA_SWAP_API_KEY}" ];
          # Bundled, store-pinned catalog. Dropped when externalConfigFile is
          # set — then the writable file owns the model set, and these GGUF
          # fetches (and the closure weight they add) drop out entirely.
          models = lib.mkIf (cfg.externalConfigFile == null) {
            "qwen2.5:0.5b" = {
              cmd = "${llama-server} -m ${qwen25-05b-gguf} --port \${PORT}" + modelArgs "qwen2.5:0.5b";
            };
            "gemma4:e2b" = {
              cmd = "${llama-server} -m ${gemma4-e2b-gguf} --port \${PORT}" + modelArgs "gemma4:e2b";
            };
            "gemma4:e4b" = {
              cmd = "${llama-server} -m ${gemma4-e4b-gguf} --port \${PORT}" + modelArgs "gemma4:e4b";
              aliases = [ "gemma4" ];
            };
          };
        };
      };

    # llama-server binary on PATH for debugging
    environment.systemPackages = [ cfg.llama-server-package ];

    # Expose the llama-swap port to Docker bridge networks so rootless
    # containers can reach it. Interface-wildcard syntax is firewall-backend
    # specific: the iptables backend accepts the "br+" form in
    # `firewall.interfaces`, but the nftables backend rejects it ("unexpected
    # +") and needs a quoted glob in a raw input rule.
    networking.firewall =
      if config.networking.nftables.enable then
        {
          extraInputRules = ''
            iifname "br-*" tcp dport ${toString cfg.port} accept
          '';
        }
      else
        {
          interfaces."br-+".allowedTCPPorts = [ cfg.port ];
        };

    # Unix socket proxy for rootless Docker containers
    systemd.services.llama-swap-socket = {
      description = "Unix socket proxy for llama-swap";
      requires = [ "llama-swap.service" ];
      after = [ "llama-swap.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.socat}/bin/socat UNIX-LISTEN:/run/llama-swap.sock,fork,mode=0666 TCP:127.0.0.1:${toString cfg.port}";
      };
    };

    # Fix llama-cpp cache directory creation
    systemd.services.llama-swap = {
      environment.XDG_CACHE_HOME = "/var/cache/llama.cpp";
      serviceConfig.CacheDirectory = "llama.cpp";
      # Inject the API key as $LLAMA_SWAP_API_KEY (referenced by settings.apiKeys
      # above) at runtime. systemd reads this as root before dropping to the
      # unit's DynamicUser, so the key file never has to be readable by that user.
      serviceConfig.EnvironmentFile = lib.mkIf (cfg.apiKeyEnvFile != null) [ cfg.apiKeyEnvFile ];
      # External writable config: load it directly and hot-reload on change.
      # Mirrors upstream's ExecStart (listen + optional TLS) but swaps the
      # store config for the writable path and adds -watch-config.
      serviceConfig.ExecStart = lib.mkIf (cfg.externalConfigFile != null) (
        lib.mkForce "${lib.getExe cfg.package} ${
          lib.escapeShellArgs (
            [
              "--listen=${cfg.listenAddress}:${toString cfg.port}"
              "--config=${cfg.externalConfigFile}"
              "-watch-config"
            ]
            ++ lib.optionals cfg.tls.enable [
              "--tls-cert-file=${cfg.tls.certFile}"
              "--tls-key-file=${cfg.tls.keyFile}"
            ]
          )
        }"
      );
    };

    # Seed the writable config once (only when missing) and ensure its
    # directory exists. tmpfiles `C` copies the baseline only if the
    # destination does not already exist, so runtime edits are never
    # clobbered by a rebuild.
    systemd.tmpfiles.rules = lib.mkIf (cfg.externalConfigFile != null) [
      "d ${builtins.dirOf cfg.externalConfigFile} 0755 root root - -"
      "C ${cfg.externalConfigFile} 0644 root root - ${externalSeed}"
    ];

    # Free GPU VRAM across sleep: stop llama-swap (and the llama-server child
    # holding VRAM) before the machine sleeps, and restart it on resume.
    #
    # Modeled on nixpkgs' own `sleep-actions` unit (config/power-management.nix):
    # one oneshot with RemainAfterExit + StopWhenUnneeded, pulled in by and
    # ordered Before sleep.target. `script` (ExecStart) runs before sleep;
    # `preStop` (ExecStop) runs on resume, when sleep.target is no longer
    # needed. Both phases belong to a single non-reentrant unit, so the stop
    # (pre-sleep) and start (post-resume) of llama-swap.service are strictly
    # serialized — they cannot collide into "Job ... canceled" the way two
    # separate suspend.target-keyed start/stop units do, and the resume action
    # re-fires on every sleep cycle.
    systemd.services.llama-swap-sleep = {
      description = "Pause llama-swap across suspend/resume";
      wantedBy = [ "sleep.target" ];
      before = [ "sleep.target" ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # Before sleep: stopping the proxy also stops llama-swap-socket
      # (Requires=llama-swap.service), freeing any model's VRAM.
      script = "${pkgs.systemd}/bin/systemctl stop llama-swap.service";
      # On resume: bring the proxy and its docker socket back. --no-block so a
      # slow model warmup never stalls the resume path.
      preStop = "${pkgs.systemd}/bin/systemctl start --no-block llama-swap.service llama-swap-socket.service";
    };
  };
}
