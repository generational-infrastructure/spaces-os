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

  # Locally-administered unicast MAC derived from the uid (unique per VM).
  macFor =
    uid:
    let
      h = lib.toLower (lib.fixedWidthString 4 "0" (lib.toHexString uid));
    in
    "02:00:00:00:${builtins.substring 0 2 h}:${builtins.substring 2 2 h}";
}
