# Shared naming/path/port helpers for the hermes microvm modules — pure
# functions of `lib`, no config access. Imported per consumer file.
{ lib }:
rec {
  vmName = user: "hermes-${user}";
  # Per-VM netfilter marker group: qemu runs AS THE OWNER (User=<user> on
  # the microvm@ unit) with this supplementary group attached, so
  # iptables can still tell guest egress from the owner's own traffic
  # (-m owner --gid-owner <this> --suppl-groups) with boot-loadable
  # static rules. A group, not a user: users.groups never feeds the
  # users.users auto-provision scan (no eval fixpoint).
  vmGroup = user: "microvm-hermes-${user}";
  baseDir = user: "/var/lib/hermes-microvm/${user}";
  # Credential set riding fw_cfg into a user's guest: the agent's secret
  # env vars plus the dashboard session token.
  credNames = ucfg: lib.attrNames ucfg.secretEnv ++ [ "dashboard_token" ];

  # Fixed guest paths
  guestStateDir = "/var/lib/hermes";
  guestHostDir = "/run/hermes-host"; # ro virtiofs: ssh keys + tz
  # Exchange dir: same absolute path in the guest, and the guest HOME.
  exchangeDir = user: "/home/${user}/hermes";
  guestWorkspace = user: "${exchangeDir user}/workspace";
  # guest vsock port the host dashboard forward targets
  dashboardGuestPort = 9119;
  # loopback bind of `hermes dashboard` behind the socat bridge
  dashboardGuestBackendPort = 9118;
  # slirp's alias for the host's loopback
  slirpHostAlias = "10.0.2.2";

  # u32 VM identity derived from the USERNAME — the stable eval-time
  # key (uids are runtime-allocated and never load-bearing here).
  # Uniqueness of the derived values is asserted in options.nix.
  identityHash = user: lib.fromHexString (builtins.substring 0 8 (builtins.hashString "sha256" user));

  # vsock CID: any unique u32 >= 3 (0, 1, 2 and 0xFFFFFFFF are reserved).
  cidFor = user: 3 + lib.mod (identityHash user) 4294967292;

  # Host AF_VSOCK port of the user's spaces-gateway bridge: u32, kept
  # out of the privileged <1024 range and below 0xFFFFFFFF
  # (VMADDR_PORT_ANY).
  spacesVsockPort = user: 1024 + lib.mod (identityHash user) 4294966271;

  # The guest's single normal user is pinned to uid 1000; virtiofsd
  # translates it to the runtime host uid (guest.nix --translate-uid).
  guestUid = 1000;

  # Locally-administered unicast MAC from the identity hash (unique per VM).
  macFor =
    user:
    let
      h = lib.toLower (lib.fixedWidthString 8 "0" (lib.toHexString (identityHash user)));
      b = i: builtins.substring (2 * i) 2 h;
    in
    "02:00:${b 0}:${b 1}:${b 2}:${b 3}";
}
