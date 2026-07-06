# Blueprint entry point for the `installer-target` host. See
# `flake.lib.mkInstallerTarget`.
#
# This host is never booted directly. Its purpose is to give
# `installer-iso.nix` something to point `storeContents` at so a
# Calamares-driven `nixos-install --system <toplevel>` finds every
# spaces store path already present on the live medium.
#
# The corresponding test (`debug/installer-target-session.nix`) boots
# the same shape as a VM and asserts niri + pi-chat start, so a
# regression in the "Calamares-shape installed system" surfaces in
# CI without going through a full ISO install.
{ flake, ... }: flake.lib.mkInstallerTarget "x86_64-linux"
