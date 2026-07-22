# Owner-match firewall: only the owner (and root) may connect to a VM's
# host-side loopback ports. qemu runs AS THE OWNER, so guest egress is
# identified by the per-VM marker group (--gid-owner --suppl-groups):
# boot-loadable, unlike a cgroup path (xt_cgroup resolves at INSERT
# time), and distinguishable from the owner's own traffic, unlike uid.
{ config, lib, ... }:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) vmGroup;

  vmMatch = user: "-m owner --gid-owner ${vmGroup user} --suppl-groups";
  llamaOn = config.services.llama-swap.enable or false;
  llamaPort = config.services.llama-swap.port or 8012;

  ownerOnlyRules = port: uid: ''
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner ${toString uid} -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -m owner --uid-owner 0 -j RETURN
    iptables -w -A hermes-microvm -p tcp --dport ${toString port} -j REJECT --reject-with tcp-reset
  '';
  firewallRules = lib.concatStrings (
    lib.mapAttrsToList (user: ucfg: ''
      ${ownerOnlyRules ucfg.dashboardPort ucfg.uid}
      ${lib.optionalString ucfg.spacesGateway.enable ''
        iptables -w -A hermes-microvm -p tcp --dport ${toString ucfg.spacesPort} ${vmMatch user} -j RETURN
        ${ownerOnlyRules ucfg.spacesPort ucfg.uid}
      ''}
      # This VM's guest egress allowlist (unit cgroup = everything the
      # guest sends to slirp's 10.0.2.2): the spaces RETURN above plus DNS
      # for slirp's resolver forwarding; everything else rejected.
      iptables -w -A hermes-microvm -p tcp --dport 53 ${vmMatch user} -j RETURN
      iptables -w -A hermes-microvm -p udp --dport 53 ${vmMatch user} -j RETURN
      ${lib.optionalString llamaOn ''
        # local brain: the guest reaches llama-swap via slirp's host alias
        # (10.0.2.2 -> host loopback); without this the trailing cgroup
        # REJECT kills it.
        iptables -w -A hermes-microvm -p tcp --dport ${toString llamaPort} ${vmMatch user} -j RETURN
      ''}
      iptables -w -A hermes-microvm ${vmMatch user} -j REJECT
    '') cfg.enabledUsers
  );
in
{
  config = lib.mkIf cfg.enable {
    networking.firewall.extraCommands = ''
      iptables -w -N hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm
      ${firewallRules}
      iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm
      iptables -w -C OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null \
        || iptables -w -A OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -D OUTPUT -o lo -p udp -m conntrack --ctstate NEW -j hermes-microvm 2>/dev/null || true
      iptables -w -F hermes-microvm 2>/dev/null || true
      iptables -w -X hermes-microvm 2>/dev/null || true
    '';
  };
}
