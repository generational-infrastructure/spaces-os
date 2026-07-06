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
  cmds = config.services.spaces.commands;

  # Declarative keybind model (single source of truth, shared with
  # modules/home/sway.nix and pinned against docs/keybindings.md by
  # checks/niri-spaces-binds). This module renders the model's
  # `niriSpawnBinds` view into upstream default-config.kdl below.
  kb = import ../keybinds.nix { inherit lib; };

  # niri has no separate spaces command modifier: its own mod-key
  # (cfg.modKey) covers both roles, so the model's "SMod" token
  # collapses to "Mod" here.
  niriChord =
    chord:
    lib.concatMapStringsSep "+" (tok: if tok == "SMod" then "Mod" else tok) (
      lib.splitString "+" chord
    );

  # Every spaces-* spawn must be a notifying wrapper actually built by
  # spaces-commands.nix — fail eval loudly if the model names one that
  # doesn't exist (e.g. after a wrapper rename).
  wrapperNames = lib.mapAttrsToList (_attr: c: c.name) cmds;
  checkedSpawn =
    spawn:
    if lib.hasPrefix "spaces-" spawn && !(lib.elem spawn wrapperNames) then
      throw "niri.nix: keybind spawn '${spawn}' is not a spaces-commands wrapper (known: ${lib.concatStringsSep ", " wrapperNames})"
    else
      spawn;

  # One sed line per model bind, injected right after `binds {`. Each
  # `a\` prepends relative to the previous one, so ascending model
  # `order` renders in DESCENDING file order — keep the orders stable:
  # the rendered kdl is pinned by checks/niri-spaces-binds.
  bindSedLine =
    bind:
    ''sed -i '/^binds {$/a\    ${niriChord bind.chord} hotkey-overlay-title="${bind.title}" { spawn "${checkedSpawn bind.spawn}"; }' $out'';
  spacesBindLines = lib.concatMapStringsSep "\n    " bindSedLine kb.niriSpawnBinds;

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
        # Spaces shortcut binds, one sed line per model entry — see
        # modules/keybinds.nix for the model (chords, wrappers, overlay
        # titles) and the niri-specific notes (XKB keysym for `/` is
        # Slash; Mod+Shift+N vs Mod+Shift+A reload the bar vs pi-chat).
        #
        # Mod+L (screen lock) overrides upstream's focus-column-right
        # (Mod+Right / Mod+L both did that — Mod+Right still works), so
        # drop the upstream bind first.
        grep -q '^    Mod+L     { focus-column-right; }$' $out  # fail loudly if upstream renamed it
        sed -i '/^    Mod+L     { focus-column-right; }$/d' $out
        ${spacesBindLines}
  '';
in
{
  # The shortcut commands niri spawns are wrappers built here; importing
  # the module declares the dependency and supplies
  # `config.services.spaces.commands` used above.
  imports = [ ./spaces-commands.nix ];

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
