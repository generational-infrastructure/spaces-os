# llama-swap service with llama-cpp built for GPU acceleration.
#
# Wraps the upstream services.llama-swap NixOS module, providing:
# - llama-cpp with Vulkan + BLAS (+ CUDA when hardware.nvidia.enabled)
# - Sensible defaults (listen address, health check timeout, log routing)
# - Unix socket proxy for rootless Docker containers
# - Suspend/resume systemd units to free GPU VRAM across sleep cycles
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
    url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf";
    sha256 = "sha256-rABp68zTmSXYNvJKiMDwyFjSBXjCmyGrfO3OZu5XaEU=";
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
  };

  config = lib.mkIf cfg.enable {

    hardware.graphics.enable = lib.mkDefault true;

    services.llama-swap =
      let
        modelArgs = id: lib.optionalString (cfg.modelExtraArgs ? ${id}) " ${cfg.modelExtraArgs.${id}}";
      in
      {
        listenAddress = "0.0.0.0";
        port = lib.mkDefault 8012;
        settings = {
          healthCheckTimeout = 3600;
          logToStdout = "both";
          models = {
            "qwen2.5:0.5b" = {
              cmd = "${llama-server} -m ${qwen25-05b-gguf} --port \${PORT}" + modelArgs "qwen2.5:0.5b";
            };
            "gemma4:e2b" = {
              cmd = "${llama-server} -m ${gemma4-e2b-gguf} --port \${PORT}" + modelArgs "gemma4:e2b";
            };
          };
        };
      };

    # llama-server binary on PATH for debugging
    environment.systemPackages = [ cfg.llama-server-package ];

    # Expose llama-swap port to Docker bridge networks
    networking.firewall.interfaces."br-+".allowedTCPPorts = [ cfg.port ];

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
    };

    # Stop llama-swap before suspend to free GPU VRAM, restart on resume
    systemd.services.llama-swap-suspend = {
      description = "Stop llama-swap before suspend";
      before = [ "systemd-suspend.service" ];
      wantedBy = [ "suspend.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.systemd}/bin/systemctl stop llama-swap.service || true
        sleep 2
      '';
    };
    systemd.services.llama-swap-resume = {
      description = "Restart llama-swap after resume";
      after = [ "systemd-suspend.service" ];
      wantedBy = [ "suspend.target" ];
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.systemd}/bin/systemctl start llama-swap.service || true
      '';
    };
  };
}
