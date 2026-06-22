# Cheap nix-eval contract for llama-swap's externalConfigFile mode
# (modules/nixos/llama-swap.nix `externalConfigFile`).
#
#   - externalConfigFile null (default) → ship the bundled, store-pinned
#     catalog: settings.models holds the qwen2.5/gemma4 set.
#   - externalConfigFile set → drop the bundled catalog (settings.models is
#     empty, so the GGUF fetchurls never enter the closure), point llama-swap
#     at the writable file with `-watch-config`, and seed it via tmpfiles.
#
# Eval-only and lazy: it reads `builtins.attrNames settings.models` (forces
# only the attrset keys, never a model's `cmd`), so the bundled GGUF
# `builtins.fetchurl`s are never realised by this test.
{ pkgs, inputs, ... }:
let

  baseModules = [
    inputs.self.nixosModules.llama-swap
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

  bundled = mkSystem [ { services.llama-swap.enable = true; } ];
  external = mkSystem [
    {
      services.llama-swap = {
        enable = true;
        apiKeyEnvFile = "/run/secrets/llama-swap.env";
        externalConfigFile = "/var/lib/llama-swap/config.yaml";
      };
    }
  ];

  externalUnit = external.config.systemd.services.llama-swap.serviceConfig;
in
pkgs.runCommand "llama-swap-external-config-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    bundledModels = builtins.toJSON (builtins.attrNames (bundled.config.services.llama-swap.settings.models or { }));
    externalModels = builtins.toJSON (builtins.attrNames (external.config.services.llama-swap.settings.models or { }));
    externalExecStart = builtins.toJSON externalUnit.ExecStart;
    externalTmpfiles = builtins.toJSON external.config.systemd.tmpfiles.rules;
  }
  ''
    set -euo pipefail

    # Default: bundled catalog present (its GGUFs are what build into the closure).
    echo "$bundledModels" | jq -e 'index("gemma4:e4b") != null' > /dev/null \
      || { echo "FAIL: bundled models = $bundledModels (expected the bundled catalog)"; exit 1; }

    # externalConfigFile set → bundled catalog dropped: no models in Nix, so no
    # GGUF fetchurls and no closure weight from them.
    echo "$externalModels" | jq -e '. == []' > /dev/null \
      || { echo "FAIL: external models = $externalModels (expected [] — catalog moves to the file)"; exit 1; }

    # ExecStart loads the writable file and hot-reloads it.
    echo "$externalExecStart" | jq -e 'test("--config=/var/lib/llama-swap/config.yaml") and test("-watch-config")' > /dev/null \
      || { echo "FAIL: external ExecStart = $externalExecStart"; exit 1; }

    # The file (and its directory) are provisioned via tmpfiles.
    echo "$externalTmpfiles" | jq -e 'any(.[]; test("/var/lib/llama-swap/config.yaml"))' > /dev/null \
      || { echo "FAIL: external tmpfiles = $externalTmpfiles (expected a rule for the config file)"; exit 1; }

    echo "OK: externalConfigFile swaps the bundled catalog for a watched writable file"
    touch "$out"
  ''
