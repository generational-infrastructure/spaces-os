# Cheap nix-eval contract: the bash-confirm allowlist must whitelist
# every `google-cli` command.
#
# bash-confirm gates each `bash` tool call behind a user confirm unless
# the command matches a regex in services.pi-chat.bashConfirm.allowPatterns
# (materialised into bash-confirm.json). The Google skill drives Gmail and
# Calendar exclusively through `google-cli`, so the production allowlist
# MUST carry `^google-cli(\s|$)` — otherwise every mail/calendar action the
# agent takes stalls on a confirm prompt.
#
# Asserts against the value an unconfigured distro host resolves (the
# distro module auto-enables pi-chat). Pure nix eval. ~3-5s.
{ pkgs, inputs, ... }:
let
  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.spaces
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
  };
  patterns = system.config.services.pi-chat.bashConfirm.allowPatterns;
in
pkgs.runCommand "pi-chat-bash-confirm-allow-google-nix-eval"
  {
    allowPatterns = inputs.nixpkgs.lib.concatStringsSep "\n" patterns;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    printf '%s\n' "$allowPatterns" | grep -Fxq '^google-cli(\s|$)' \
      || fail "google-cli is not whitelisted in services.pi-chat.bashConfirm.allowPatterns: [$allowPatterns]"

    touch "$out"
  ''
