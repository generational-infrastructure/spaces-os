# Blueprint entry point for the test-machine host.
#
# Wires the shared module list + host config into a NixOS system.
# Blueprint calls this with { flake, inputs, hostName }.
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
      flake.nixosModules.spaces
      ./configuration.nix
    ];
  };
}
