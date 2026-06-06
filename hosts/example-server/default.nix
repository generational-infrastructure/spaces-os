# Blueprint entry point for the `example-server` host.
#
# A template for a headless spaces-os server. Copy this directory to
# `hosts/<your-host>/`, rename the hostname in `configuration.nix`,
# fill in the hardware bits, and drop in a real SSH key.
#
# It wires the hardened `nixosModules.server` profile (the headless
# counterpart to `nixosModules.spaces`) into a NixOS system. Blueprint
# calls this with { flake, inputs, hostName } and publishes the result
# as `nixosConfigurations.example-server`.
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
      inputs.self.nixosModules.server
      ./configuration.nix
    ];
  };
}
