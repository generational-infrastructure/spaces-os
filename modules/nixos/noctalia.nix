# Noctalia Wayland desktop shell.
#
# Installs noctalia-shell (patched with plugins-autoload support) and
# symlinks the pi-chat plugin into the autoload directory so it
# is enabled automatically when noctalia starts.
#
# The patched build is wired in via `nixpkgs.overlays`, so any
# `pkgs.noctalia-shell` reference anywhere in the consumer's config
# resolves to the patched derivation — including home-manager wrappers
# that re-wrap it for their own env vars.
#
# Consumers whose nixpkgs ships a noctalia-shell version that the patch
# was NOT generated against (currently ≥ 4.7.6) will see patchPhase
# fail; bump nixpkgs, or grab the prebuilt
# `inputs.distro.packages.<sys>.noctalia-shell` directly (built from
# distro's own nixpkgs pin) and skip importing this module.
#
# `runNixOSTest` defaults to `pkgsReadOnly = true`, which makes
# `nixpkgs.overlays` unmergeable from inside a node. Tests that import
# this module must set `node.pkgsReadOnly = false;` (see
# `checks/test-machine.nix`).
{ flake, ... }:
{ pkgs, ... }:
{
  config = {
    nixpkgs.overlays = [ flake.overlays.noctalia ];

    environment.systemPackages = [
      pkgs.noctalia-shell
      pkgs.libnotify
    ];

    # Symlink pi-chat into the autoload directory so noctalia
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
      restartTriggers = [ pkgs.noctalia-shell ];
      serviceConfig = {
        ExecStart = "${pkgs.noctalia-shell}/bin/noctalia-shell";
        Restart = "on-failure";
        Slice = "session.slice";
        # Noctalia spawns helpers by bare name (`sh`, `wl-paste`, `voxtype`, ...)
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
