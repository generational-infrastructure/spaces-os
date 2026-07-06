# aarch64-linux variant of the `installer` host. See
# `flake.lib.mkInstallerHost`.
#
# Build with:
#   nix build .#iso.aarch64-linux.installer
{ flake, ... }: flake.lib.mkInstallerHost "aarch64-linux"
