# Niri scrollable-tiling Wayland compositor.
#
# Enables niri and supporting services its default config relies on
# (polkit, secret-service, swaylock PAM, terminal/launcher/lock tools).
# Aligned with https://wiki.nixos.org/wiki/Niri "Additional Setup".
#
# Also writes a deterministic /etc/niri/config.kdl derived from the
# upstream default with two opinionated edits:
#   1. spawn-at-startup "waybar" → "noctalia-shell" (we ship noctalia)
#   2. inject `mod-key "Alt"` so VMs don't fight host Super grabs
#
# NIRI_CONFIG is set on the user-service unit to bypass niri's user/system
# config lookup and avoid niri auto-creating ~/.config/niri/config.kdl
# (which would shadow our system config).
#
# enableDefaultPath = false on niri.service: the NixOS default injects a
# stripped Environment=PATH= which prevents niri's bare-name `spawn`
# actions from finding /run/current-system/sw/bin programs.
{ pkgs, ... }:
let
  niriConfig = pkgs.runCommand "niri-config.kdl" { } ''
    cp ${pkgs.niri.src}/resources/default-config.kdl $out
    chmod +w $out
    substituteInPlace $out \
      --replace-fail 'spawn-at-startup "waybar"' \
                     'spawn-at-startup "noctalia-shell"'
    sed -i '/^input {$/a\    mod-key "Alt"' $out
    # Super+A toggles the opencrow-chat panel in noctalia.
    sed -i '/^binds {$/a\    Super+A hotkey-overlay-title="Toggle AI Chat" { spawn "noctalia-shell" "ipc" "call" "plugin:opencrow-chat" "toggle"; }' $out
    # Super+S toggles voice-to-text recording.
    sed -i '/^binds {$/a\    Super+S hotkey-overlay-title="Voice to Text" { spawn "voxtype" "record" "toggle"; }' $out
  '';
in
{
  programs.niri.enable = true;

  # polkit authentication agent (required by noctalia and swaylock).
  security.polkit.enable = true;

  # Secret Service backend.
  services.gnome.gnome-keyring.enable = true;

  # PAM stack for swaylock.
  security.pam.services.swaylock = { };

  # Tools the niri default config and keybinds expect.
  environment.systemPackages = with pkgs; [
    alacritty # Super+T
    fuzzel # Super+D
    swaylock # Super+Alt+L
    swayidle # idle management
    xwayland-satellite # XWayland integration
  ];

  environment.etc."niri/config.kdl".source = niriConfig;

  systemd.user.services.niri = {
    environment.NIRI_CONFIG = toString niriConfig;
    enableDefaultPath = false;
  };
}
