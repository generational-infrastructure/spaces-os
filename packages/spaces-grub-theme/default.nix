# Spaces OS GRUB boot-menu theme: nixos-grub2-theme with its header
# logo.png replaced by the Spaces OS wordmark. The wordmark SVG is the
# source of truth, rasterised here to fit theme.txt's 319x100 header slot.
#
# theme.txt declares the header as a fixed image { width=319 height=100 },
# and grub scales whatever PNG it finds to *exactly* 319x100, ignoring
# aspect. The ~6:1 wordmark rendered to full width is only 319x53, so grub
# stretched it ~1.9x vertically into a squished wordmark. Instead render it
# letterboxed: rasterise at a legible width keeping true aspect, then
# composite it centered onto a transparent 319x100 canvas so grub's scale
# is 1:1. Background stays transparent (the theme's light header shows
# through; the wordmark is dark #000).
#
# The wordmark SVG comes from the shared `spaces-logos` fetchgit FOD.
{
  pkgs,
  spaces-logos ? pkgs.callPackage ../spaces-logos { },
  ...
}:
pkgs.runCommand "spaces-grub2-theme"
  {
    nativeBuildInputs = [
      pkgs.librsvg
      pkgs.graphicsmagick
    ];
  }
  ''
    cp -r ${pkgs.nixos-grub2-theme} $out
    chmod -R u+w $out
    rsvg-convert -w 290 ${spaces-logos}/spaces-logo-wordmark.svg -o wm.png
    gm convert -size 319x100 xc:none canvas.png
    gm composite -gravity center wm.png canvas.png $out/logo.png
  ''
