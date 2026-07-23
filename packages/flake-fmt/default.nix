# Mic92's smart `nix fmt` wrapper (caches the flake's formatter). Built from
# the pinned source's own package.nix against our nixpkgs.
{ pkgs, inputs, ... }:
pkgs.callPackage "${inputs.flake-fmt}/package.nix" { }
