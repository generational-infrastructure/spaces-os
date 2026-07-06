# Declarative keybind model — the single source of truth for spaces
# bindings. Renderers:
#   - modules/home/sway.nix   consumes `defaults` (home-manager sway
#     keybindings; maps neutral actions to sway syntax)
#   - modules/nixos/niri.nix  consumes `niriSpawnBinds` (sed-injects
#     spawn binds into upstream default-config.kdl)
#   - docs/keybindings.md     documents every bind; pinned against this
#     model by checks/niri-spaces-binds
#
# This is a PLAIN data file, deliberately outside modules/{nixos,home}:
# blueprint publishes every entry of those two trees as a module output,
# and this is not a module. Import it by path:
#   kb = import ../keybinds.nix { inherit lib; };
#
# Bind entry shape (exactly one of spawn/action/command):
#   spawn        program to exec (a spaces-* wrapper for agent shortcuts)
#   action       neutral WM action name (sway.nix maps it to sway syntax)
#   command      raw sway command escape hatch
#   description  human label (docs, hotkey overlays)
#   sway         optional bool (default true): rendered by sway.nix
#   niri         optional { title, order }: sed-injected into niri's kdl
#                as `<chord> hotkey-overlay-title="<title>" { spawn …; }`.
#                `order` fixes the injection sequence (ascending); the
#                rendered kdl is byte-pinned by checks/niri-spaces-binds,
#                so keep it stable unless you mean to move a bind.
{ lib }:
let

  # spaces-* spawns are the notifying shortcut wrappers from
  # modules/nixos/spaces-commands.nix (on PATH on every spaces host);
  # going through them means a failed shortcut posts a desktop
  # notification instead of silently doing nothing.
  #
  # These agent shortcuts use the "SMod" token (the spaces command modifier),
  # not "Mod" (the window-manager modifier), so a downstream config can relocate
  # just the agent binds -- e.g. keep them on Super while window management moves
  # to Alt. SMod defaults to Mod; see modules/home/sway.nix. In niri's kdl both
  # tokens collapse to "Mod" (niri's own modifier, services.spaces.niri.modKey).
  spawnDefaults = {
    "SMod+A" = {
      spawn = "spaces-chat-toggle";
      description = "Toggle AI Chat";
      niri = {
        title = "Toggle AI Chat";
        order = 10;
      };
    };
    "SMod+Slash" = {
      spawn = "spaces-chat-quick-launch";
      description = "Quick-launch Agent";
      niri = {
        title = "Quick-launch Agent";
        order = 20;
      };
    };
    "SMod+S" = {
      spawn = "spaces-voice-record-toggle";
      description = "Voice to Text";
      niri = {
        title = "Voice to Text";
        order = 30;
      };
    };
    "SMod+Shift+N" = {
      spawn = "spaces-bar-reload";
      description = "Reload bar";
      niri = {
        title = "Reload Noctalia Bar";
        order = 40;
      };
    };
    "SMod+Shift+A" = {
      spawn = "spaces-chat-reload";
      description = "Reload pi-chat";
      # niri-only: kept off sway to preserve its existing keybinding
      # surface (the sway module never bound the pi-chat reload).
      sway = false;
      niri = {
        title = "Reload pi-chat";
        order = 50;
      };
    };
    "SMod+L" = {
      spawn = "spaces-screen-lock";
      description = "Lock screen";
      niri = {
        title = "Lock the Screen: swaylock";
        order = 60;
      };
    };
    "Ctrl+Alt+L" = {
      spawn = "spaces-screen-lock";
      description = "Lock screen";
      niri = {
        title = "Lock the Screen: swaylock";
        order = 70;
      };
    };
    "Mod+Return" = {
      spawn = "alacritty";
      description = "Terminal";
    };
  };

  navDefaults =
    let
      vimKeys = {
        left = "H";
        down = "J";
        up = "K";
        right = "L";
      };
      arrowKeys = {
        left = "Left";
        down = "Down";
        up = "Up";
        right = "Right";
      };
      focusBinds = lib.mapAttrs' (
        dir: key:
        lib.nameValuePair "Mod+${key}" {
          action = "focus-${dir}";
          description = "Focus ${dir}";
        }
      ) arrowKeys;
      moveBinds = lib.mapAttrs' (
        dir: key:
        lib.nameValuePair "Mod+Shift+${key}" {
          action = "move-${dir}";
          description = "Move ${dir}";
        }
      ) vimKeys;
    in
    focusBinds
    // moveBinds
    // {
      "Mod+Shift+Q" = {
        action = "close-window";
        description = "Close window";
      };
      "Mod+F" = {
        action = "fullscreen";
        description = "Fullscreen";
      };
      "Mod+Shift+Space" = {
        action = "toggle-float";
        description = "Toggle floating";
      };
      "Mod+Shift+R" = {
        action = "reload-config";
        description = "Reload config";
      };
      "Mod+Shift+E" = {
        action = "quit";
        description = "Exit compositor";
      };
    };

  workspaceDefaults =
    let
      switch = map (n: {
        name = "Mod+${toString n}";
        value = {
          action = "workspace-switch-${toString n}";
          description = "Workspace ${toString n}";
        };
      }) (lib.range 1 9);
      move = map (n: {
        name = "Mod+Shift+${toString n}";
        value = {
          action = "workspace-move-${toString n}";
          description = "Move to workspace ${toString n}";
        };
      }) (lib.range 1 9);
    in
    lib.listToAttrs (switch ++ move);

  binds = spawnDefaults // navDefaults // workspaceDefaults;
in
{
  modifierDefault = "Mod4";

  # The full model, one entry per bind.
  inherit binds;

  # Sway view: everything not explicitly opted out. sway.nix renders
  # exactly this set (extra niri/sway metadata is ignored there).
  defaults = lib.filterAttrs (_chord: bind: bind.sway or true) binds;

  # Niri view: the spawn binds injected into upstream default-config.kdl,
  # as an ordered list of { chord, spawn, title, order }.
  niriSpawnBinds = lib.sort (a: b: a.order < b.order) (
    lib.mapAttrsToList (
      chord: bind: {
        inherit chord;
        inherit (bind) spawn;
        inherit (bind.niri) title order;
      }
    ) (lib.filterAttrs (_chord: bind: bind ? niri) binds)
  );
}
