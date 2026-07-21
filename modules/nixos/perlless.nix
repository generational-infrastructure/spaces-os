# Perl-free system: drop perl from activation, the initrd, and the default
# package set. Mirrors nixpkgs' profiles/perlless.nix. Everything is mkDefault,
# so a host that genuinely needs perl — e.g. a BIOS GRUB machine, whose
# install-grub.sh is perl — can opt back in (set boot.loader.grub.enable = true).
{ lib, ... }:
{
  boot.initrd.systemd.enable = lib.mkDefault true;
  system.etc.overlay.enable = lib.mkDefault true;

  # Odds and ends that still drag perl in.
  boot.enableContainers = lib.mkDefault false;
  boot.loader.grub.enable = lib.mkDefault false;
  documentation.info.enable = lib.mkDefault false;
  environment.defaultPackages = lib.mkDefault [ ];
  programs.command-not-found.enable = lib.mkDefault false;
  programs.less.lessopen = lib.mkDefault null;
  system.disableInstallerTools = lib.mkDefault true;
}
