# Spaces module bundle: every NixOS module Spaces ships, plus a
# greetd auto-login into niri.
{ inputs, ... }:
{ config, lib, ... }:
{
  imports = [
    # AI chat Quickshell panel + pi --mode rpc backend
    inputs.self.nixosModules.pi-chat
    # local LLM server with bundled GGUF models
    inputs.self.nixosModules.llama-swap
    # signal-cli daemon + bridge for the signal skill
    inputs.self.nixosModules.signal-cli
    # push-to-talk voice-to-text (Mod+S)
    inputs.self.nixosModules.voxtype
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
