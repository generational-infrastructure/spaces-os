# Patched noctalia-shell: nixpkgs's package + distro's plugins-autoload
# patch.
#
# Built from distro's own nixpkgs pin, so the patch always matches the
# QML layout it was generated against (currently ≥ 4.7.6). Consumers
# whose nixpkgs ships a different version can grab this prebuilt
# directly via `inputs.distro.packages.${system}.noctalia-shell` instead
# of registering the overlay and re-patching their own nixpkgs.
{ inputs, pkgs, ... }:
inputs.self.lib.patchNoctaliaShell pkgs.noctalia-shell
