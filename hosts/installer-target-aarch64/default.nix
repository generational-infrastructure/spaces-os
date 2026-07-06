# aarch64-linux variant of the `installer-target` host. See
# `flake.lib.mkInstallerTarget`.
#
# Like its x86_64 sibling, this host is never booted directly — it
# only exists to give the aarch64 ISO a representative installed
# system to copy into the live store.
{ flake, ... }: flake.lib.mkInstallerTarget "aarch64-linux"
