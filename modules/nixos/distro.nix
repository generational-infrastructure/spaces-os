# Distro module bundle.
#
# Single import that pulls in every NixOS module this distro provides:
# the standalone pi-chat Quickshell panel + its pi --mode rpc backend,
# the llama-swap LLM-serving module, signal-cli for the signal skill,
# voxtype for the voice-to-text button, the niri compositor, and VM
# debug + nix tooling.
#
# Configures greetd to auto-login into niri by default. Override
# `services.greetd` in your host config to customise.
#
# Users who want the noctalia desktop shell can run it themselves —
# distro no longer bundles it. The pi-chat panel coexists with any
# Wayland shell; layer-shell compositors only (no GNOME — see
# modules/nixos/pi-chat/default.nix for the constraint).
{ inputs, ... }:
{ config, lib, ... }:
{
  imports = [
    inputs.self.nixosModules.pi-chat
    inputs.self.nixosModules.llama-swap
    inputs.self.nixosModules.signal-cli
    inputs.self.nixosModules.voxtype
    inputs.self.nixosModules.niri
    inputs.self.nixosModules.vm-debug
    inputs.self.nixosModules.nix
  ];

  services.pi-chat.enable = lib.mkDefault true;

  services.greetd = {
    enable = lib.mkDefault true;
    settings.default_session = {
      command = lib.mkDefault "${config.programs.niri.package}/bin/niri-session";
      user = lib.mkDefault "alice";
    };
  };
}
