# Spaces module bundle: every NixOS module Spaces ships, plus a
# greetd auto-login into niri.
{ inputs, ... }:
{ config, lib, ... }:
{
  imports = [
    # AI chat Quickshell panel + loopback pi-sessiond executor
    inputs.self.nixosModules.pi-chat
    # local LLM server with bundled GGUF models
    inputs.self.nixosModules.llama-swap
    # one-shot 'distro' → 'spaces' user-state migration
    inputs.self.nixosModules.spaces-state-migrate
    # noctalia status bar (vanilla, no plugin)
    inputs.self.nixosModules.noctalia
    # niri scrollable-tiling Wayland compositor
    inputs.self.nixosModules.niri
    # QEMU display/audio/clipboard/SSH for nix build .#test-vm
    inputs.self.nixosModules.vm-debug
    # nix daemon settings (flakes, experimental features)
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
