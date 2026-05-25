# Blueprint entry point for the UTM-on-Apple-Silicon image host.
#
# Pairs with hosts/utm-aarch64/configuration.nix to produce a qcow2
# disk image that boots directly in UTM's QEMU backend (with
# virtio-gpu-gl-pci) so niri has a real DRM render node. The
# Virtualization.framework backend exposes only 2D virtio-gpu and
# will not satisfy niri's render-node requirement.
#
# Build with:
#   nix build .#image.aarch64-linux.utm
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
      { nixpkgs.hostPlatform = "aarch64-linux"; }
      flake.nixosModules.distro
      ./configuration.nix
    ];
  };
}
