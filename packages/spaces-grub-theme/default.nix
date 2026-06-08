# Spaces OS GRUB boot-menu theme: nixos-grub2-theme re-packaged so its
# header logo.png can be swapped for a Spaces OS mark. The mark is a
# binary asset that lands later, so for now this is the upstream theme
# unchanged.
{ pkgs, ... }:
pkgs.runCommand "spaces-grub2-theme" { } ''
  cp -r ${pkgs.nixos-grub2-theme} $out
  chmod -R u+w $out
  # TODO: overwrite $out/logo.png with the Spaces OS mark once it exists.
''
