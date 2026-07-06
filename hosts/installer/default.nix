# Blueprint entry point for the `installer` host — the bootable
# graphical installer ISO image. See `flake.lib.mkInstallerHost`.
#
# Build the ISO with:
#   nix build .#iso.x86_64-linux.installer
{ flake, ... }: flake.lib.mkInstallerHost "x86_64-linux"
