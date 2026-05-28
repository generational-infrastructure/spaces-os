# Cheap nix-eval contract for the distro-specific niri keybinds.
#
# The standalone-chat migration once silently repurposed Mod+Shift+N
# (noctalia bar reload) to pi-chat. This pins the two reload binds so a
# future refactor can't clobber one unnoticed.
{ pkgs, inputs, ... }:
let
  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.niri
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
  niriConfig = system.config.environment.etc."niri/config.kdl".source;
in
pkgs.runCommand "niri-distro-binds-test" { inherit niriConfig; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }

  # Mod+Shift+N reloads the noctalia bar.
  grep -qE 'Mod\+Shift\+N .*"restart" "noctalia-shell\.service"' "$niriConfig" \
    || fail "Mod+Shift+N must restart noctalia-shell.service"

  # Mod+Shift+A reloads the pi-chat agent panel.
  grep -qE 'Mod\+Shift\+A .*"restart" "pi-chat\.service"' "$niriConfig" \
    || fail "Mod+Shift+A must restart pi-chat.service"

  # Regression guard: the noctalia chord must not be the pi-chat one.
  if grep -qE 'Mod\+Shift\+N .*"pi-chat\.service"' "$niriConfig"; then
    fail "Mod+Shift+N is bound to pi-chat — noctalia bar reload was clobbered"
  fi

  touch "$out"
''
