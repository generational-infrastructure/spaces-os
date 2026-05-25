# aarch64-linux variant of the `installer` host.
#
# Same shape as ./installer/default.nix — only the hostPlatform
# differs. installer-iso.nix picks `installer-target-aarch64` for
# storeContents when it sees an aarch64 hostPlatform, so the
# pre-staged installed-system closure matches the live medium's arch.
#
# Build with:
#   nix build .#iso.aarch64-linux.installer
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
      ../../modules/nixos/installer-iso.nix
    ];
  };
}
