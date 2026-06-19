# Cheap nix-eval contract for llama-swap's optional API-key auth
# (modules/nixos/llama-swap.nix `apiKeyEnvFile`).
#
#   - apiKeyEnvFile set  → llama-swap requires the key: settings.apiKeys
#     references the `${env.LLAMA_SWAP_API_KEY}` macro (so the secret stays out
#     of the store-rendered config.yaml) and the unit's EnvironmentFile points
#     at the supplied file (systemd injects the key at runtime).
#   - apiKeyEnvFile null → upstream default-allow: no apiKeys, no EnvironmentFile.
#
# Eval-only and lazy: it reads `settings.apiKeys` / `serviceConfig.EnvironmentFile`
# without forcing `settings.models`, so the GGUF `builtins.fetchurl`s never run.
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

  withKey = mkSystem [
    {
      services.llama-swap = {
        enable = true;
        apiKeyEnvFile = "/run/secrets/llama-swap.env";
      };
    }
  ];
  noKey = mkSystem [ { services.llama-swap.enable = true; } ];

  withKeyUnit = withKey.config.systemd.services.llama-swap.serviceConfig;
  noKeyUnit = noKey.config.systemd.services.llama-swap.serviceConfig;
in
pkgs.runCommand "llama-swap-auth-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    withKeyApiKeys = builtins.toJSON withKey.config.services.llama-swap.settings.apiKeys;
    noKeyApiKeys = builtins.toJSON noKey.config.services.llama-swap.settings.apiKeys;
    withKeyEnvFile = builtins.toJSON withKeyUnit.EnvironmentFile;
    noKeyEnvFile = builtins.toJSON (noKeyUnit.EnvironmentFile or null);
  }
  ''
    set -euo pipefail

    # apiKeyEnvFile set → require the key (apiKeys references the env macro) and
    # load it via systemd EnvironmentFile (secret stays out of the store).
    echo "$withKeyApiKeys" | jq -e '. == ["''${env.LLAMA_SWAP_API_KEY}"]' > /dev/null \
      || { echo "FAIL: with-key apiKeys = $withKeyApiKeys"; exit 1; }
    echo "$withKeyEnvFile" | jq -e '. == ["/run/secrets/llama-swap.env"]' > /dev/null \
      || { echo "FAIL: with-key EnvironmentFile = $withKeyEnvFile"; exit 1; }

    # apiKeyEnvFile null (default) → default-allow: no apiKeys, no EnvironmentFile.
    echo "$noKeyApiKeys" | jq -e '. == []' > /dev/null \
      || { echo "FAIL: no-key apiKeys = $noKeyApiKeys (expected default-allow [])"; exit 1; }
    echo "$noKeyEnvFile" | jq -e '. == null' > /dev/null \
      || { echo "FAIL: no-key EnvironmentFile = $noKeyEnvFile (expected unset)"; exit 1; }

    echo "OK: apiKeyEnvFile gates llama-swap auth (apiKeys + EnvironmentFile)"
    touch "$out"
  ''
