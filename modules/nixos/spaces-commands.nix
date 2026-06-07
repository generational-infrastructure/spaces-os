# Wrappers for every command bound to a spaces keyboard shortcut.
#
# The compositor spawns these instead of the raw commands so that:
#   - each shortcut goes through a binary we own (greppable on PATH,
#     runnable from a terminal, a single place to evolve behaviour), and
#   - a failure posts a "failed to <label>" desktop notification instead
#     of the shortcut silently doing nothing.
#
# The notifying wrapper builder lives in lib/spaces-command.nix (the
# central library). This module instantiates one wrapper per spaces
# shortcut and publishes the set as `config.services.spaces.commands`
# so the compositor module references the exact names and can't drift
# from what is actually installed.
#
# Underlying commands and notify-send are resolved from the session
# PATH — same as the compositor's bare-name spawns — so the wrappers
# carry no package closure and stay cheap to evaluate.
{
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
      # Recording state is shown by the on-screen voxtype indicator (a red
      # dot, top-right — see voxtype-indicator.nix), so no transition
      # toast here; just flip the daemon. A failure still posts the
      # mkCommand "failed to …" toast.
      text = "voxtype record toggle";
    };
    bar-reload = mkCommand {
      name = "spaces-bar-reload";
      label = "reload the status bar";
      text = "systemctl --user restart noctalia-shell.service";
    };
    chat-reload = mkCommand {
      name = "spaces-chat-reload";
      label = "reload the chat panel";
      # daemon-reload picks up a rebuild's new unit defs, then restart
      # re-runs the panel's materialize ExecStartPre against fresh QML.
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

  config.environment.systemPackages = lib.attrValues commands ++ [
    # The wrappers call notify-send by bare name to post their failure
    # toast; guarantee it is on the system PATH.
    pkgs.libnotify
  ];
}
