{ lib }:
let

  spawnDefaults = {
    "Mod+A" = {
      spawn = "pi-chat-toggle";
      description = "Toggle AI Chat";
    };
    "Mod+Slash" = {
      spawn = "pi-chat-toggle quickLaunch";
      description = "Quick-launch Agent";
    };
    "Mod+S" = {
      spawn = "voxtype record toggle";
      description = "Voice to Text";
    };
    "Mod+L" = {
      spawn = "swaylock";
      description = "Lock screen";
    };
    "Ctrl+Alt+L" = {
      spawn = "swaylock";
      description = "Lock screen";
    };
    "Mod+Shift+N" = {
      spawn = "systemctl --user restart noctalia-shell.service";
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
