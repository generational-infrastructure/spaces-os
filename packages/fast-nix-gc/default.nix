# Mic92's faster nix-collect-garbage. Built from the pinned source's own
# package.nix against our nixpkgs.
{ pkgs, inputs, ... }:
pkgs.callPackage "${inputs.fast-nix-gc}/nix/package.nix" { }
