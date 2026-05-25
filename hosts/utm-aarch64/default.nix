# Blueprint host for the UTM aarch64 image — see configuration.nix.
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
