# Distro module bundle.
#
# Single import that pulls in every NixOS module this distro provides.
# Builds on noctalia-bar (which includes noctalia-plugin: pi-chat +
# llama-swap, plus voxtype) and adds niri compositor + VM debug
# support.
#
# Configures greetd to auto-login into niri by default.  Override
# `services.greetd` in your host config to customise.
{ inputs, ... }:
{ config, lib, ... }:
{
  imports = [
    inputs.self.nixosModules.noctalia-bar
    inputs.self.nixosModules.niri
    inputs.self.nixosModules.vm-debug
    inputs.self.nixosModules.nix
  ];

  services.greetd = {
    enable = lib.mkDefault true;
    settings.default_session = {
      command = lib.mkDefault "${config.programs.niri.package}/bin/niri-session";
      user = lib.mkDefault "alice";
    };
  };
}
