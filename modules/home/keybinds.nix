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
  # to Alt. SMod defaults to Mod; see modules/home/sway.nix.
  spawnDefaults = {
    "SMod+A" = {
      spawn = "spaces-chat-toggle";
      description = "Toggle AI Chat";
    };
    "SMod+Slash" = {
      spawn = "spaces-chat-quick-launch";
      description = "Quick-launch Agent";
    };
    "SMod+S" = {
      spawn = "spaces-voice-record-toggle";
      description = "Voice to Text";
    };
    "SMod+L" = {
      spawn = "spaces-screen-lock";
      description = "Lock screen";
    };
    "Ctrl+Alt+L" = {
      spawn = "spaces-screen-lock";
      description = "Lock screen";
    };
    "SMod+Shift+N" = {
      spawn = "spaces-bar-reload";
      description = "Reload bar";
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
in
{
  modifierDefault = "Mod4";
  defaults = spawnDefaults // navDefaults // workspaceDefaults;
}
