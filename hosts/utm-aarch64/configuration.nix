# aarch64 qcow2 for UTM's QEMU backend on Apple Silicon. The
# Virtualization.framework backend exposes only 2D virtio-gpu and
# won't satisfy niri's DRM render-node requirement, so this image
# expects QEMU + virtio-gpu-gl-pci where virgl provides
# /dev/dri/renderD128.
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

  # UTM mints fresh NVRAM per VM, so anything that registers an EFI
  # boot entry loses it across restarts. installAsRemovable boots
  # from the \EFI\BOOT\BOOTAA64.EFI fallback path instead.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.timeout = 1;

  # ttyAMA0 surfaces in UTM's serial tab; hvc0 covers virtio-console;
  # tty0 keeps the framebuffer (and the greeter) alive.
  boot.kernelParams = [
    "console=ttyAMA0,115200n8"
    "console=hvc0"
    "console=tty0"
  ];

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

  # Super collides with the macOS Command grab; Alt is what
  # test-machine uses for the same reason.
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
