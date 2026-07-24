# Hermes Agent (NousResearch) in per-user MicroVMs (microvm.nix): one
# fully declarative VM per user, qemu + slirp egress + vsock channels.
# Architecture, trust model and model-seed rules: docs/hermes.md.
# INVARIANT: never open the state-vault sqlite DBs from the host while
# a VM runs (WAL on virtiofs is only guest-coherent) — see docs/hermes.md.
#
# Layout:
#   options.nix  — option interface, auto-provisioning, assertions
#   vms.nix      — microvm.vms registration (applies guest.nix per user)
#   guest.nix    — the guest NixOS system (function: user -> ucfg -> module)
#   host.nix     — host wiring: unit drop-ins, sockets, tmpfiles, groups
#   firewall.nix — iptables owner/marker-group chain
#   cli.nix      — `hermes`/`hermes-desktop` shims + .desktop entries
#   scripts.nix  — provisioning script builders (host.nix only)
#   lib.nix      — shared names/paths/ports
#   guest-python.nix — writable pip venv for the guests
# Blueprint wraps THIS file with the publisher's (spaces') `inputs`;
# vms.nix/cli.nix need them too (hermes-agent, microvm) and must get
# them explicitly — as plain module args they would resolve to the
# CONSUMER flake's specialArgs, which need not carry hermes-agent.
{ inputs, ... }:
let
  # Publisher-inputs injection with a stable dedup key: an anonymous
  # function module has none, so importing nixosModules.hermes twice
  # (desktop alias + a direct site import) would apply these twice —
  # guest.nix would then declare the upstream hermes-agent options
  # twice inside every VM. The key (the file's store path) is identical
  # on both import routes.
  withInputs = path: {
    _file = path;
    key = path;
    imports = [ (import path { inherit inputs; }) ];
  };
in
{
  imports = [
    inputs.microvm.nixosModules.host
    inputs.self.nixosModules.openrouter
    ./options.nix
    (withInputs ./vms.nix)
    ./host.nix
    ./firewall.nix
    (withInputs ./cli.nix)
  ];
}
