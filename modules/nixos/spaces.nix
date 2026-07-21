# Back-compat: `nixosModules.spaces` is the full desktop, as it was before the
# `spaces.profile` role switch existed. It layers the GUI/agent module tree on
# top of the lean `nixosModules.default` (base + profile switch) and selects the
# `desktop` profile. New consumers who only want the base (e.g. a server) should
# import `nixosModules.default` and set `spaces.profile` themselves.
#
# The desktop modules are imported HERE, not in `default`, because they pull
# heavy closures (pi-chat → voxtype ASR models, unconditionally) that must never
# reach a `server` — and NixOS imports can't be gated on the profile value.
{ inputs, ... }:
{ lib, config, ... }:
{
  imports = [
    inputs.self.nixosModules.default
    # AI chat Quickshell panel + loopback pi-sessiond executor
    inputs.self.nixosModules.pi-chat
    # local LLM server (models added at runtime)
    inputs.self.nixosModules.llama-swap
    # noctalia status bar
    inputs.self.nixosModules.noctalia
    # niri scrollable-tiling Wayland compositor
    inputs.self.nixosModules.niri
    # QEMU display/audio/clipboard/SSH for nix build .#test-vm
    inputs.self.nixosModules.vm-debug
  ];

  config = lib.mkMerge [
    { spaces.profile = lib.mkDefault "desktop"; }

    # The `desktop` profile's enables (moved from default.nix, since they enable
    # the modules imported just above).
    (lib.mkIf (config.spaces.profile == "desktop") {
      services.pi-chat.enable = lib.mkDefault true;
      services.spaces.niri.enable = lib.mkDefault true;
      services.noctalia.enable = lib.mkDefault true;

      services.greetd = {
        enable = lib.mkDefault true;
        settings.default_session = {
          command = lib.mkDefault "${config.programs.niri.package}/bin/niri-session";
          user = lib.mkDefault "alice";
        };
      };
    })
  ];
}
