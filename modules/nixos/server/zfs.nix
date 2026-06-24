# ZFS defaults. Adapted from srvos common/zfs
# (Copyright (c) 2023 Numtide, MIT — see ./LICENSE).
{ config, lib, ... }:
{
  # Same default hostID as the NixOS install ISO and nixos-anywhere, so
  # pools import without a force import. ZFS uses hostID as an ISCSI
  # safety mechanism, but in practice it mostly causes unbootable
  # machines while ZFS-on-ISCSI is rare.
  networking.hostId = lib.mkDefault "8425e349";

  services.zfs = lib.mkIf config.boot.zfs.enabled {
    autoSnapshot.enable = lib.mkDefault true;
    # Default is 12 monthly snapshots — too many given write volume.
    autoSnapshot.monthly = lib.mkDefault 1;
    autoScrub.enable = lib.mkDefault true;
  };
}
