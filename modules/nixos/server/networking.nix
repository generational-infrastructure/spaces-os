# Networking defaults for servers. Adapted from srvos common/networking
# (Copyright (c) 2023 Numtide, MIT — see ./LICENSE).
{ lib, ... }:
{
  # Firewall on by default; servers opt ports in explicitly.
  networking.firewall.enable = true;

  # Allow PMTU / DHCP.
  networking.firewall.allowPing = true;

  # Keep `dmesg` / `journalctl -k` readable by not logging every
  # refused connection on the open internet.
  networking.firewall.logRefusedConnections = lib.mkDefault false;

  # Prevent LLMNR poisoning attacks.
  services.resolved.settings.Resolve.LLMNR = lib.mkDefault "false";

  # Use networkd rather than the legacy scripted networking.
  networking.useNetworkd = lib.mkDefault true;

  # Don't block boot waiting for network-online.
  # https://github.com/systemd/systemd/blob/main/NEWS
  systemd.services.NetworkManager-wait-online.enable = false;
  systemd.network.wait-online.enable = false;

  # Don't take the network down for long during upgrades: restart
  # rather than stop+delayed-start, so services that merely restart
  # can still resolve.
  systemd.services.systemd-networkd.stopIfChanged = false;
  systemd.services.systemd-resolved.stopIfChanged = false;
}
