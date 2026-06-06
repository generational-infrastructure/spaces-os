# example-server host configuration — a template headless server.
#
# The `server` profile (wired in by default.nix) already provides the
# hardened baseline: sshd (keys only), firewall on, immutable users,
# execWheelOnly sudo, networkd, UTC, watchdog, serial console, ZFS
# defaults. This file only carries what is host-specific.
#
# Things you MUST change before deploying:
#   - networking.hostName
#   - the SSH key under users.users.admin (you are locked out otherwise:
#     the server profile sets users.mutableUsers = false)
#   - the disk / bootloader layout to match the real hardware
_:

{
  networking.hostName = "example-server";

  # Bootloader / disk.
  # EFI + systemd-boot is the common case. For a BIOS/grub host set
  # boot.loader.grub.enable + boot.loader.grub.device instead. Replace
  # the placeholder device with the real one (lsblk / by-uuid) — or,
  # better, generate this block with disko / nixos-generate-config.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  swapDevices = [ ];

  # Admin user.
  # mutableUsers is false, so this key is the only way onto the box. The
  # value below is a non-functional placeholder that only exists so the
  # template builds — REPLACE it with your real public key before
  # deploying, or you will be locked out.
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAREPLACE_THIS_PLACEHOLDER_KEY replace-me@example"
    ];
  };

  # Server workload.
  # The natural server role in this repo is the remote-pi executor
  # (pi-sessiond): a headless box that hosts pi sessions over a
  # token-authenticated WebSocket for desktop clients to drive. Enable
  # and configure as needed:
  #
  # services.pi-sessiond = {
  #   enable = true;
  #   port = 8765;
  #   openFirewall = true;        # let remote clients reach the listener
  #   tokenFile = "/run/secrets/pi-sessiond-token";
  #   executorId = "example-server";
  # };

  # Pick the timezone you actually operate in if UTC (the profile
  # default) isn't what you want for logs:
  # time.timeZone = "Europe/Berlin";

  system.stateVersion = "26.05";
}
