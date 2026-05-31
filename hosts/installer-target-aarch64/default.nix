# aarch64-linux variant of the `installer-target` host.
#
# Mirrors ./installer-target/default.nix with hostPlatform =
# aarch64-linux so `installer-iso.nix` on aarch64 has a matching
# pre-staged closure to point storeContents at.
#
# Like its x86_64 sibling, this host is never booted directly — it
# only exists to give the aarch64 ISO a representative installed
# system to copy into the live store.
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
      inputs.self.nixosModules.spaces
      ../installer-target/configuration.nix
    ];
  };
}
