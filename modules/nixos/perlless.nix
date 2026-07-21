# Perl-free system: drop perl from activation, the initrd, and the default
# package set. Import nixpkgs' own perlless profile rather than copying it (a
# copy silently drifts as upstream slims the list), but don't *enforce*
# perl-free: the base can't guarantee it — a BIOS GRUB host's install-grub.sh is
# perl — so keep the forbidden-dependency check off and just drop perl where it
# can be dropped.
{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/profiles/perlless.nix" ];
  system.forbiddenDependenciesRegexes = lib.mkForce [ ];
}
