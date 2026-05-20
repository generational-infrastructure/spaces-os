# Noctalia Wayland desktop shell.
#
# Installs noctalia-shell (patched with plugins-autoload support) and
# symlinks the opencrow-chat plugin into the autoload directory so it
# is enabled automatically when noctalia starts.
#
# The patched package is materialized by extending `pkgs` locally rather
# than by registering an overlay on `nixpkgs.overlays`. NixOS test
# frameworks (and any other consumer that pins nixpkgs read-only) make
# `nixpkgs.overlays` unmergeable, so a module-level overlay assignment
# breaks `nix flake check`. `pkgs.extend` sidesteps that without
# changing the resulting derivation.
{ flake, ... }:
{ pkgs, ... }:
let
  pkgs' = pkgs.extend flake.overlays.noctalia;
in
{
  config = {
    environment.systemPackages = [
      pkgs'.noctalia-shell
      pkgs.libnotify
    ];

    # Symlink opencrow-chat into the autoload directory so noctalia
    # auto-enables it and places its bar widget in the center section.
    systemd.user.tmpfiles.rules = [
      "d %h/.config 0755 - - -"
      "d %h/.config/noctalia 0755 - - -"
      "d %h/.config/noctalia/plugins-autoload 0755 - - -"
    ];

    systemd.user.services.noctalia-shell = {
      description = "Noctalia Wayland desktop shell";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      restartTriggers = [ pkgs'.noctalia-shell ];
      serviceConfig = {
        ExecStart = "${pkgs'.noctalia-shell}/bin/noctalia-shell";
        Restart = "on-failure";
        Slice = "session.slice";
        # Noctalia spawns helpers by bare name (`sh`, `wl-paste`, `voxtype`, ...)
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
