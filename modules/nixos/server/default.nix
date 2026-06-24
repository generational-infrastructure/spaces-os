# Server profile (flake.nixosModules.server).
#
# Hardened headless baseline adapted from nix-community/srvos's
# `server` + `common` profiles. The server-side counterpart to
# `nixosModules.spaces` (the desktop bundle); import it on hosts with
# no graphical session.
#
# Portions Copyright (c) 2023 Numtide, MIT-licensed — see ./LICENSE.
{ inputs, ... }:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
{
  imports = [
    # nix-command + flakes experimental features.
    inputs.self.nixosModules.nix

    ./networking.nix
    ./openssh.nix
    ./sudo.nix
    ./serial.nix
    ./zfs.nix
    ./detect-hostname-change.nix
  ];

  options.spaces.server = {
    docs.enable = lib.mkEnableOption "NixOS documentation on servers" // {
      description = "Whether to build the NixOS manual and man pages. Off by default on servers.";
    };
  };

  config = {
    # Trim graphical bits and shrink the closure.
    programs.git.package = lib.mkDefault pkgs.gitMinimal;

    documentation.nixos.enable = lib.mkDefault config.spaces.server.docs.enable;

    # No graphical bits on a server.
    fonts.fontconfig.enable = lib.mkDefault false;
    programs.command-not-found.enable = lib.mkDefault false;
    xdg.autostart.enable = lib.mkDefault false;
    xdg.icons.enable = lib.mkDefault false;
    xdg.menus.enable = lib.mkDefault false;
    xdg.mime.enable = lib.mkDefault false;
    xdg.sounds.enable = lib.mkDefault false;

    environment = {
      # Print the URL instead of trying to launch a browser.
      variables.BROWSER = "echo";
      # Don't install the /lib/ld-linux.so.2 and
      # /lib64/ld-linux-x86-64.so.2 stubs.
      stub-ld.enable = lib.mkDefault false;
      # Don't install the 32-bit dynamic loader either — saves one
      # instance of nixpkgs.
      ldso32 = null;
    };

    # vim as the default editor (and install it if the option exists).
    programs.vim = {
      defaultEditor = lib.mkDefault true;
    }
    // lib.optionalAttrs (options.programs.vim ? enable) {
      enable = lib.mkDefault true;
    };

    # Boot / generations.
    # Cap boot entries so a full /boot doesn't brick the machine.
    boot.loader.grub.configurationLimit = lib.mkDefault 5;
    boot.loader.systemd-boot.configurationLimit = lib.mkDefault 5;

    boot.tmp.cleanOnBoot = lib.mkDefault true;

    # Identity / time.
    # Delegate the hostname to dhcp/cloud-init by default. mkOverride
    # 1337 sits *below* mkDefault (1000), so any host that sets a
    # hostname (even via mkDefault) wins.
    networking.hostName = lib.mkOverride 1337 "";

    time.timeZone = lib.mkDefault "UTC";

    # No mutable users by default — declare them in Nix.
    users.mutableUsers = false;

    # Create users with userborn rather than the legacy perl script,
    # unless impermanence or per-user subuid/subgid ranges are in play
    # (both incompatible with userborn's defaults).
    services.userborn.enable = lib.mkIf (
      !(
        (options.environment ? persistence)
        || (lib.any (u: u.subUidRanges != [ ] || u.autoSubUidGidRange) (lib.attrValues config.users.users))
      )
    ) (lib.mkDefault true);

    # Resilience.
    systemd = {
      # Headless boxes can't be rescued from an emergency-mode prompt;
      # keep booting so we can reach them over the network.
      enableEmergencyMode = false;

      sleep.settings.Sleep = {
        AllowSuspend = "no";
        AllowHibernation = "no";
      };

      # Hardware watchdog. systemd pings it at half the interval, so
      # every 7.5s here. See https://0pointer.de/blog/projects/watchdog.html
      settings.Manager = {
        RuntimeWatchdogSec = lib.mkDefault "15s";
        RebootWatchdogSec = lib.mkDefault "30s";
        KExecWatchdogSec = lib.mkDefault "1m";
      };
    };

    # nix daemon scheduling.
    # De-duplicate the store with hardlinks, except in containers where
    # the store is host-managed.
    nix.optimise.automatic = lib.mkDefault (!config.boot.isContainer);

    # Members of @wheel are trusted.
    nix.settings.trusted-users = [ "@wheel" ];

    # Keep builds from starving interactive work.
    nix.daemonCPUSchedPolicy = lib.mkDefault "batch";
    nix.daemonIOSchedClass = lib.mkDefault "idle";
    nix.daemonIOSchedPriority = lib.mkDefault 7;
    systemd.services.nix-gc.serviceConfig = {
      CPUSchedulingPolicy = "batch";
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
    };
    # Under memory pressure, prefer killing a (restartable) build over a service.
    systemd.services.nix-daemon.serviceConfig.OOMScoreAdjust = lib.mkDefault 250;

    # Make the serial console visible under `nixos-rebuild build-vm`.
    virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;
  };
}
