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

  gemma4-12b-gguf =
    quant: sha256:
    builtins.fetchurl {
      url = "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-${quant}.gguf";
      inherit sha256;
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
        # Plain assignment (priority 100): beats upstream's option
        # default of 8080 (priority 1500). Users override with
        # `lib.mkForce <port>` if they need something other than 8012.
        port = 8012;
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
            "gemma4:e4b" = {
              cmd = "${llama-server} -m ${gemma4-e4b-gguf} --port \${PORT}" + modelArgs "gemma4:e4b";
              aliases = [ "gemma4" ];
            };
            "gemma4:12b-ud-q3_k_xl" = {
              cmd =
                "${llama-server} -m ${gemma4-12b-gguf "UD-Q3_K_XL" "sha256-YK6JHl1ZBB7hX9nMWZro0s/oVJ900eGQoU4wdrZuqvE="} --port \${PORT}"
                + modelArgs "gemma4:12b-ud-q3_k_xl";
            };
            "gemma4:12b-q4_k_m" = {
              cmd =
                "${llama-server} -m ${gemma4-12b-gguf "Q4_K_M" "sha256-Q/7JjFECscRGtN3QqUOfHbOi4fLguM0UPOHqYZqUA9Y="} --port \${PORT}"
                + modelArgs "gemma4:12b-q4_k_m";
            };
            "gemma4:12b-ud-q4_k_xl" = {
              cmd =
                "${llama-server} -m ${gemma4-12b-gguf "UD-Q4_K_XL" "sha256-7jOrW+jgesocJp/GRertXzKY4InVLbKUFYOdjymVcCA="} --port \${PORT}"
                + modelArgs "gemma4:12b-ud-q4_k_xl";
            };
            "gemma4:12b-q5_k_m" = {
              cmd =
                "${llama-server} -m ${gemma4-12b-gguf "Q5_K_M" "sha256-G8Yz7JiBeFi+wQ9z+gJkgclmJEmq5LgKBd+yjveEwng="} --port \${PORT}"
                + modelArgs "gemma4:12b-q5_k_m";
            };
            "gemma4:12b-q6_k" = {
              cmd =
                "${llama-server} -m ${gemma4-12b-gguf "Q6_K" "sha256-4WAt3CJMFZWE60x9amyNaC/Gr7LvuPdsEL/WO6cUNqI="} --port \${PORT}"
                + modelArgs "gemma4:12b-q6_k";
            };
            "gemma4:12b-q8_0" = {
              cmd =
                "${llama-server} -m ${gemma4-12b-gguf "Q8_0" "sha256-dNLU8LWwjKhYnRpfUOaJwJhEafPO29x9Z0WMbp41SWo="} --port \${PORT}"
                + modelArgs "gemma4:12b-q8_0";
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
