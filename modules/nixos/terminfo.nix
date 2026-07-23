# terminfo entries for terminals that aren't installed on the host but connect
# to it over ssh (ghostty, wezterm, foot, kitty), so keys/colours work remotely.
# Derived from srvos (https://github.com/nix-community/srvos),
# MIT © Numtide — see LICENSES/srvos.MIT.
{
  pkgs,
  lib,
  ...
}:
{
  environment.systemPackages = [
    pkgs.wezterm.terminfo # ships prebuilt, no compilation
    (pkgs.runCommand "ghostty-terminfo"
      {
        nativeBuildInputs = [ pkgs._7zz ];
      }
      ''
        7zz -snld x ${pkgs.ghostty-bin.src}
        mkdir -p $out/share/terminfo/{g,x}
        cp -r Ghostty.app/Contents/Resources/terminfo/67/ghostty $out/share/terminfo/g
        cp -r Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty $out/share/terminfo/x
      ''
    )
  ]
  ++ lib.optionals (pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform) [
    pkgs.foot.terminfo
    pkgs.kitty.terminfo
  ];
}
