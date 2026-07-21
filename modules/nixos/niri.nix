# Niri scrollable-tiling Wayland compositor, its supporting services, and a
# deterministic /etc/niri/config.kdl derived from the upstream default.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.spaces.niri;
  cmds = config.services.spaces.commands;

  # Declarative keybind model, shared with modules/home/sway.nix and pinned by
  # checks/niri-spaces-binds. Its `niriSpawnBinds` view renders into the kdl below.
  kb = import ../keybinds.nix { inherit lib; };

  # niri has no separate spaces command modifier, so the model's "SMod" token
  # collapses to niri's own mod-key ("Mod") here.
  niriChord =
    chord:
    lib.concatMapStringsSep "+" (tok: if tok == "SMod" then "Mod" else tok) (lib.splitString "+" chord);

  # Fail eval if the model names a spaces-* spawn that spaces-commands.nix
  # doesn't build (e.g. after a wrapper rename).
  wrapperNames = lib.mapAttrsToList (_attr: c: c.name) cmds;
  checkedSpawn =
    spawn:
    if lib.hasPrefix "spaces-" spawn && !(lib.elem spawn wrapperNames) then
      throw "niri.nix: keybind spawn '${spawn}' is not a spaces-commands wrapper (known: ${lib.concatStringsSep ", " wrapperNames})"
    else
      spawn;

  # One sed line per model bind, injected after `binds {`. Each `a\` prepends
  # relative to the previous, so ascending model `order` renders in DESCENDING
  # file order — the rendered kdl is pinned by checks/niri-spaces-binds.
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
        # Replace upstream's (mostly-comment) touchpad block with our libinput defaults.
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
        # Spaces shortcut binds, one sed line per model entry (see modules/keybinds.nix).
        # Our Mod+L (screen lock) collides with upstream's focus-column-right, so drop
        # that bind first; Mod+Right still does focus-column-right.
        grep -q '^    Mod+L     { focus-column-right; }$' $out  # fail loudly if upstream renamed it
        sed -i '/^    Mod+L     { focus-column-right; }$/d' $out
        ${spacesBindLines}
  '';
in
{
  # Supplies the shortcut wrappers niri spawns (config.services.spaces.commands).
  imports = [ ./spaces-commands.nix ];

  options.services.spaces.niri.enable = lib.mkEnableOption ''
    the niri scrollable-tiling Wayland compositor and its supporting
    services (polkit, gnome-keyring, swaylock PAM, terminal/launcher/lock
    tools, and the deterministic /etc/niri/config.kdl)'';

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

  config = lib.mkIf cfg.enable {
    programs.niri.enable = true;

    security.polkit.enable = true; # required by swaylock
    services.gnome.gnome-keyring.enable = true; # Secret Service backend
    security.pam.services.swaylock = { };

    # Tools the niri default config and keybinds expect.
    environment.systemPackages = with pkgs; [
      alacritty # Super+T
      fuzzel # Super+D
      swaylock # Super+Alt+L
      swayidle
      xwayland-satellite
    ];

    environment.etc."niri/config.kdl".source = niriConfig;

    systemd.user.services.niri = {
      # Stable /etc symlink (not the store path) so niri live-reloads config on
      # deploy: canonicalize() changes when the symlink is re-pointed, and an
      # explicit NIRI_CONFIG stops niri auto-creating ~/.config/niri/config.kdl.
      environment.NIRI_CONFIG = "/etc/niri/config.kdl";
      # NixOS default injects a stripped PATH= that hides /run/current-system/sw/bin
      # from niri's bare-name `spawn` actions.
      enableDefaultPath = false;
      restartIfChanged = false; # don't kill the desktop on deploy
    };
  };
}
