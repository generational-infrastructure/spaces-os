# UTM (Apple Silicon) qcow2 image configuration.
#
# Targets UTM's QEMU backend specifically — Apple's
# Virtualization.framework only exposes virtio-gpu 2D, which doesn't
# satisfy niri's DRM render-node requirement. In UTM create the VM
# with "QEMU 7.2+ ARM Virtual Machine (virt)" and select
# `virtio-gpu-gl-pci` as the display device so virgl exposes
# /dev/dri/renderD128 to the guest.
#
# system.build.qcowImage produces the qcow2-compressed image consumed
# by the flake's `image.aarch64-linux.utm` output.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = "distro-utm";
  networking.networkmanager.enable = true;
  time.timeZone = "Etc/UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # GRUB-EFI with installAsRemovable: UTM mints a fresh NVRAM per VM,
  # so anything that registers an EFI boot entry (systemd-boot,
  # canTouchEfiVariables) loses its entry across UTM restarts. The
  # \EFI\BOOT\BOOTAA64.EFI fallback path is the only thing UTM's UEFI
  # firmware finds reliably.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.timeout = 1;

  # Serial on QEMU virt is ttyAMA0; UTM exposes it in the "serial"
  # tab. hvc0 covers the virtio-console fallback. tty0 keeps the
  # framebuffer (and thus the GNOME greeter) alive.
  boot.kernelParams = [
    "console=ttyAMA0,115200n8"
    "console=hvc0"
    "console=tty0"
  ];

  # First-boot grows the root partition to whatever size UTM gave the
  # VM. Without this the root FS is stuck at the build-time
  # additionalSpace.
  boot.growPartition = true;

  boot.initrd.availableKernelModules = [
    "virtio_blk"
    "virtio_pci"
    "virtio_gpu"
    "virtio_net"
    "virtio_scsi"
    "virtio_console"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # Default user matches the password so the image is usable without
  # any out-of-band credentials sharing. distro's greetd module
  # autologs in whoever is set as default_session.user.
  users.users.distro = {
    isNormalUser = true;
    uid = 1000;
    initialPassword = "distro";
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
    ];
  };
  services.greetd.settings.default_session.user = "distro";

  # niri inside UTM-QEMU shares its Super grab with macOS's
  # Command/Option layout. Alt keeps the guest WM and host shortcuts
  # from fighting.
  services.distro.niri.modKey = "Alt";

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  system.stateVersion = "25.05";

  system.build.qcowImage = import (modulesPath + "/../lib/make-disk-image.nix") {
    inherit lib config pkgs;
    name = "distro-utm-aarch64";
    format = "qcow2-compressed";
    partitionTableType = "efi";
    diskSize = "auto";
    additionalSpace = "2048M";
    copyChannel = false;
  };
}
