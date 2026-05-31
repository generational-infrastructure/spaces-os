# Niri scrollable-tiling Wayland compositor.
#
# Enables niri and supporting services its default config relies on
# (polkit, secret-service, swaylock PAM, terminal/launcher/lock tools).
# Aligned with https://wiki.nixos.org/wiki/Niri "Additional Setup".
#
# Also writes a deterministic /etc/niri/config.kdl derived from the
# upstream default with two opinionated edits:
#   1. drop spawn-at-startup "waybar" (spaces hosts pick their own bar)
#   2. set the modifier key from `services.spaces.niri.modKey`
#      (default "Super"; VM-based test runners flip it to "Alt" so
#      the guest doesn't fight the host's Super grab — see
#      `modules/nixos/test-support` and `checks/test-machine.nix`).
#
# NIRI_CONFIG is the stable /etc/niri/config.kdl symlink, not the pinned
# store path. Explicit path → niri skips its user/system lookup and won't
# auto-create ~/.config/niri/config.kdl. niri's watcher reloads when
# canonicalize(path) changes, so re-pointing the /etc symlink on deploy
# live-reloads the binds; the store path's canonical form never moved,
# which is why keybind edits used to need a relogin.
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
  cfg = config.services.spaces.niri;
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
        # Mod+A toggles the standalone pi-chat panel.
        sed -i '/^binds {$/a\    Mod+A hotkey-overlay-title="Toggle AI Chat" { spawn "pi-chat-toggle"; }' $out
        # Mod+S toggles voice-to-text recording.
        sed -i '/^binds {$/a\    Mod+S hotkey-overlay-title="Voice to Text" { spawn "voxtype" "record" "toggle"; }' $out
        # Mod+Shift+N reloads the noctalia bar. Mod+Shift+A reloads
        # pi-chat: daemon-reload picks up a rebuild's new unit defs, then
        # restart re-runs the panel's materialize ExecStartPre and
        # relaunches against the fresh QML — no session logout needed.
        sed -i '/^binds {$/a\    Mod+Shift+N hotkey-overlay-title="Reload Noctalia Bar" { spawn "systemctl" "--user" "restart" "noctalia-shell.service"; }' $out
        sed -i '/^binds {$/a\    Mod+Shift+A hotkey-overlay-title="Reload pi-chat" { spawn "sh" "-c" "systemctl --user daemon-reload; systemctl --user restart pi-chat.service"; }' $out
        # Mod+L and Ctrl+Alt+L lock the screen with swaylock. Mod+L
        # overrides upstream's focus-column-right (Mod+Right / Mod+L
        # both did that — Mod+Right still works).
        grep -q '^    Mod+L     { focus-column-right; }$' $out  # fail loudly if upstream renamed it
        sed -i '/^    Mod+L     { focus-column-right; }$/d' $out
        sed -i '/^binds {$/a\    Mod+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "swaylock"; }' $out
        sed -i '/^binds {$/a\    Ctrl+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "swaylock"; }' $out
  '';
in
{
  options.services.spaces.niri.modKey = lib.mkOption {
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

    # polkit authentication agent (required by swaylock).
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
      # Stable /etc symlink, not the store path, so niri live-reloads on
      # deploy (see header).
      environment.NIRI_CONFIG = "/etc/niri/config.kdl";
      enableDefaultPath = false;
      # Avoid killing the desktop on deploy
      restartIfChanged = false;
    };
  };
}
