# Cheap nix-eval contract for services.noctalia.bar.position — the per-host
# knob that pins the noctalia bar edge in the managed settings.json (deep-
# merged into ~/.config/noctalia on every service start, so it wins over UI
# edits to that key). Asserts on the real rendered artifact: the
# noctalia-settings.json referenced by the noctalia-shell ExecStartPre merge
# script. Cases:
#   - defaults            -> bar.position == "top"
#   - position = "bottom" -> bar.position == "bottom"
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  baseModules = [
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
    lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ [ inputs.self.nixosModules.noctalia ] ++ extra;
    };

  defaultSystem = mkSystem [ ];
  bottomSystem = mkSystem [ { services.noctalia.bar.position = "bottom"; } ];

  # The merge script's closure carries the generated noctalia-settings.json;
  # the check greps the script for that store path and asserts on the JSON.
  mergeScript = system: system.config.systemd.user.services.noctalia-shell.serviceConfig.ExecStartPre;
in
pkgs.runCommand "noctalia-bar-position-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    defaultMerge = mergeScript defaultSystem;
    bottomMerge = mergeScript bottomSystem;
  }
  ''
    set -euo pipefail

    settingsOf() {
      grep -o '/nix/store/[a-z0-9]*-noctalia-settings\.json' "$1" | head -n1
    }

    defaultSettings=$(settingsOf "$defaultMerge")
    [ -n "$defaultSettings" ] || { echo "FAIL: no settings.json referenced by $defaultMerge"; exit 1; }
    pos=$(jq -r '.bar.position' "$defaultSettings")
    [ "$pos" = "top" ] || { echo "FAIL: default bar.position=$pos, want top"; exit 1; }

    bottomSettings=$(settingsOf "$bottomMerge")
    [ -n "$bottomSettings" ] || { echo "FAIL: no settings.json referenced by $bottomMerge"; exit 1; }
    pos=$(jq -r '.bar.position' "$bottomSettings")
    [ "$pos" = "bottom" ] || { echo "FAIL: bar.position=$pos, want bottom"; exit 1; }

    echo "OK: default pins top; services.noctalia.bar.position=bottom pins bottom"
    touch "$out"
  ''
