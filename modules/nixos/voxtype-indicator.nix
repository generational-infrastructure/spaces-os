# On-screen voxtype recording indicator.
#
# A standalone Quickshell layer-shell overlay (a small red dot, top-right)
# that lights up while voxtype is capturing audio — the persistent,
# glanceable replacement for the transient "voice recording started/
# stopped" notifications. It reads `voxtype status --follow` (the daemon's
# state file, already enabled via state_file = "auto" in voxtype.nix).
#
# Standalone on purpose: the noctalia bar runs vanilla ("no plugin"), so
# the indicator is its own quickshell config rather than a bar widget,
# and stays alive across bar reloads. Mirrors the pi-chat service idiom
# (materialize QML with fresh mtimes for Qt's qmlcache, then run
# `quickshell -c <name>`).
#
# Imported by voxtype.nix; gated on spaces.voxtype.indicator.enable.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.spaces.voxtype.indicator;

  shellDir = ../../programs/voxtype-indicator;
  shellName = "voxtype-indicator";

  materializeShell = pkgs.writeShellScript "voxtype-indicator-materialize" ''
    set -eu
    src=${shellDir}
    dst="$HOME/.config/quickshell/${shellName}"
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    # cp without -p leaves mtimes at the current time so Qt's qmlcache
    # re-reads the QML after a rebuild.
    cp -rT "$src" "$dst"
    chmod -R u+w "$dst"
  '';
in
{
  options.spaces.voxtype.indicator = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        On-screen recording indicator: a small dot that turns red while
        voxtype is capturing audio (recording or streaming) and amber
        while transcribing. Replaces the voice-recording notifications.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.voxtype-indicator = {
      description = "Voxtype on-screen recording indicator";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      restartTriggers = [ shellDir ];
      serviceConfig = {
        ExecStartPre = "${materializeShell}";
        ExecStart = "${pkgs.quickshell}/bin/quickshell -c ${shellName}";
        Restart = "on-failure";
        RestartSec = 3;
        Slice = "session.slice";
        # The QML's Process spawns `voxtype` by bare name; give the unit
        # the standard session PATH (same as noctalia / pi-chat).
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
