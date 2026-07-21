# Back-compat: `nixosModules.spaces` is the full desktop, as it was before the
# `spaces.profile` role switch existed. New consumers should import
# `nixosModules.default` and set `spaces.profile` explicitly.
{ inputs, ... }:
{ lib, ... }:
{
  imports = [ inputs.self.nixosModules.default ];
  spaces.profile = lib.mkDefault "desktop";
}
