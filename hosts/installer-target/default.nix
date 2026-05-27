# Blueprint entry point for the `installer-target` host.
#
# This host is never booted directly. Its purpose is to give
# `installer-iso.nix` something to point `storeContents` at so a
# Calamares-driven `nixos-install --system <toplevel>` finds every
# distro store path already present on the live medium.
#
# The corresponding test (`debug/installer-target-session.nix`) boots
# the same shape as a VM and asserts niri + pi-chat start, so a
# regression in the "Calamares-shape installed system" surfaces in
# CI without going through a full ISO install.
{
  inputs,
  flake,
  hostName,
}:
{
  class = "nixos";
  value = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs flake hostName;
    };
    modules = [
      { nixpkgs.hostPlatform = "x86_64-linux"; }
      inputs.self.nixosModules.distro
      ./configuration.nix
    ];
  };
}
