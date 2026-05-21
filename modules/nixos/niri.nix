# Niri scrollable-tiling Wayland compositor.
#
# Enables niri and supporting services its default config relies on
# (polkit, secret-service, swaylock PAM, terminal/launcher/lock tools).
# Aligned with https://wiki.nixos.org/wiki/Niri "Additional Setup".
#
# Also writes a deterministic /etc/niri/config.kdl derived from the
# upstream default with two opinionated edits:
#   1. drop spawn-at-startup "waybar" (noctalia starts via systemd)
#   2. set the modifier key from `services.distro.niri.modKey`
#      (default "Super"; VM-based test runners flip it to "Alt" so
#      the guest doesn't fight the host's Super grab — see
#      `modules/nixos/test-support` and `checks/test-machine.nix`).
#
# NIRI_CONFIG is set on the user-service unit to bypass niri's user/system
# config lookup and avoid niri auto-creating ~/.config/niri/config.kdl
# (which would shadow our system config).
#
# enableDefaultPath = false on niri.service: the NixOS default injects a
# stripped Environment=PATH= which prevents niri's bare-name `spawn`
# actions from finding /run/current-system/sw/bin programs.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.distro.niri;
  niriConfig = pkgs.runCommand "niri-config.kdl" { } ''
    cp ${pkgs.niri.src}/resources/default-config.kdl $out
    chmod +w $out
    grep -q 'spawn-at-startup "waybar"' $out  # fail loudly if upstream renamed it
    sed -i '/spawn-at-startup "waybar"/d' $out
    sed -i '/^input {$/a\    mod-key "${cfg.modKey}"' $out
    # Replace upstream's touchpad block (mostly comments) with our
    # opinionated libinput defaults: clickfinger button mapping, tap to
    # click, drag-lock, natural scrolling, etc.
    grep -q '^    touchpad {$' $out  # fail loudly if upstream renamed it
    sed -i '/^    touchpad {$/,/^    }$/d' $out
    sed -i '/^    mouse {$/i\
    touchpad {\
        tap\
        dwt\
        dwtp\
        drag true\
        drag-lock\
        natural-scroll\
        click-method "clickfinger"\
        tap-button-map "left-right-middle"\
    }\

' $out
    # Super+A toggles the pi-chat panel in noctalia.
    sed -i '/^binds {$/a\    Super+A hotkey-overlay-title="Toggle AI Chat" { spawn "noctalia-shell" "ipc" "call" "plugin:pi-chat" "toggle"; }' $out
    # Super+S toggles voice-to-text recording.
    sed -i '/^binds {$/a\    Super+S hotkey-overlay-title="Voice to Text" { spawn "voxtype" "record" "toggle"; }' $out
  '';
in
{
  options.services.distro.niri.modKey = lib.mkOption {
    type = lib.types.enum [
      "Super"
      "Alt"
    ];
    default = "Super";
    description = ''
      Modifier key used by niri's keybinds. Defaults to "Super" for
      bare-metal installs. VM-based test runners override this to
      "Alt" so the guest does not fight the host compositor's Super
      grab.
    '';
  };

  config = {
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
      # Avoid killing the desktop on deploy
      restartIfChanged = false;
    };
  };
}
