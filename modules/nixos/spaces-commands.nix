# Notifying wrappers for every command bound to a spaces keyboard shortcut,
# published as `config.services.spaces.commands` so the compositor references
# exact names and can't drift from what's installed. A failure posts a
# "failed to <label>" desktop notification instead of silently doing nothing.
#
# Underlying commands and notify-send resolve from the session PATH, so the
# wrappers carry no package closure and stay cheap to evaluate.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  mkCommand = import ../../lib/spaces-command.nix pkgs;

  commands = {
    chat-toggle = mkCommand {
      name = "spaces-chat-toggle";
      label = "toggle the AI chat panel";
      text = "pi-chat-toggle";
    };
    chat-quick-launch = mkCommand {
      name = "spaces-chat-quick-launch";
      label = "open the quick-launch agent bar";
      text = "pi-chat-toggle quickLaunch";
    };
    voice-record-toggle = mkCommand {
      name = "spaces-voice-record-toggle";
      label = "toggle voice recording";
      # Read the state first so the transition toast can name the direction.
      text = ''
        state=$(voxtype status) || state=idle
        voxtype record toggle
        if [ "$state" = recording ]; then
          spaces_notify "voice recording stopped" 2000
        else
          spaces_notify "voice recording started" 2000
        fi
      '';
    };
    bar-reload = mkCommand {
      name = "spaces-bar-reload";
      label = "reload the status bar";
      text = "systemctl --user restart noctalia-shell.service";
    };
    chat-reload = mkCommand {
      name = "spaces-chat-reload";
      label = "reload the chat panel";
      # daemon-reload picks up a rebuild's new unit defs before the restart.
      text = ''
        systemctl --user daemon-reload
        systemctl --user restart pi-chat.service
      '';
    };
    screen-lock = mkCommand {
      name = "spaces-screen-lock";
      label = "lock the screen";
      text = "swaylock";
    };
  };
in
{
  options.services.spaces.commands = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    internal = true;
    readOnly = true;
    default = commands;
    description = ''
      Wrappers for the commands bound to spaces keyboard shortcuts,
      keyed by a short id. Each runs its underlying command and posts a
      "failed to …" desktop notification on failure. The compositor
      module spawns them by bare name (they are on the system PATH).
    '';
  };

  # Gated: only put the wrappers on PATH when a compositor/bar that binds them is
  # enabled (the option above stays published unconditionally). Read the enables
  # via `? …` so a standalone import (option only, no niri/noctalia tree) evaluates
  # to "no compositor → no packages" instead of throwing on the missing option.
  config.environment.systemPackages =
    let
      s = config.services;
      niriOn = s.spaces.niri.enable or false;
      noctaliaOn = s.noctalia.enable or false;
    in
    lib.mkIf (niriOn || noctaliaOn) (
      lib.attrValues commands
      ++ [
        # The wrappers call notify-send by bare name for their failure toast.
        pkgs.libnotify
      ]
    );
}
