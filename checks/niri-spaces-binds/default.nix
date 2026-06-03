# Cheap nix-eval contract for the spaces-specific niri keybinds.
#
# Every spaces shortcut must spawn a controlled spaces-* wrapper (see
# modules/nixos/spaces-commands.nix), never a raw command, so a failed
# shortcut posts a desktop notification. The wrapper names are read back
# from the evaluated system so this check and niri.nix can't drift.
#
# The standalone-chat migration once silently repurposed Mod+Shift+N
# (noctalia bar reload) to pi-chat; the regression guard pins that the
# bar-reload chord is not the chat-reload wrapper.
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
  cmds = system.config.services.spaces.commands;
in
pkgs.runCommand "niri-spaces-binds-test"
  {
    inherit niriConfig;
    chatToggle = cmds.chat-toggle.name;
    chatQuickLaunch = cmds.chat-quick-launch.name;
    voiceRecordToggle = cmds.voice-record-toggle.name;
    barReload = cmds.bar-reload.name;
    chatReload = cmds.chat-reload.name;
    screenLock = cmds.screen-lock.name;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # Each spaces chord spawns its dedicated notifying wrapper.
    grep -qE "Mod\+A .*spawn \"$chatToggle\"" "$niriConfig" \
      || fail "Mod+A must spawn $chatToggle"
    grep -qE "Mod\+Slash .*spawn \"$chatQuickLaunch\"" "$niriConfig" \
      || fail "Mod+Slash must spawn $chatQuickLaunch (quick-launch agent bar)"
    grep -qE "Mod\+S .*spawn \"$voiceRecordToggle\"" "$niriConfig" \
      || fail "Mod+S must spawn $voiceRecordToggle"
    grep -qE "Mod\+Shift\+N .*spawn \"$barReload\"" "$niriConfig" \
      || fail "Mod+Shift+N must spawn $barReload (noctalia bar reload)"
    grep -qE "Mod\+Shift\+A .*spawn \"$chatReload\"" "$niriConfig" \
      || fail "Mod+Shift+A must spawn $chatReload (pi-chat reload)"
    grep -qE "Mod\+L .*spawn \"$screenLock\"" "$niriConfig" \
      || fail "Mod+L must spawn $screenLock"
    grep -qE "Ctrl\+Alt\+L .*spawn \"$screenLock\"" "$niriConfig" \
      || fail "Ctrl+Alt+L must spawn $screenLock"

    # Guard the chords spaces rebinds away from their old raw commands:
    # these tokens must now only appear inside the wrapper names, never
    # as a bare spawn target on a spaces chord. (Upstream's own
    # Super+Alt+L swaylock bind is intentionally left untouched.)
    for chord in 'Mod\+A' 'Mod\+Slash' 'Mod\+S' 'Mod\+Shift\+N' 'Mod\+Shift\+A'; do
      if grep -qE "$chord .*\{ spawn \"(pi-chat-toggle|voxtype|systemctl|sh)\"" "$niriConfig"; then
        fail "$chord spawns a raw command instead of a spaces-* wrapper"
      fi
    done
    # Regression guard: the noctalia bar chord must not be the pi-chat one.
    if grep -qE "Mod\+Shift\+N .*spawn \"$chatReload\"" "$niriConfig"; then
      fail "Mod+Shift+N is bound to the pi-chat reload — noctalia bar reload was clobbered"
    fi

    touch "$out"
  ''
