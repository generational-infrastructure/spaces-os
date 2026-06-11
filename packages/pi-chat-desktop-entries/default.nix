# Freedesktop launcher entries + hicolor icon for the pi-chat panel and
# its quick-launch bar, so both are summonable from app launchers.
#
# The icon is composed at build time from the canonical Spaces mark in
# the shared `spaces-logos` fetchgit FOD.
#
# Exec uses the bare `pi-chat-toggle` name: the wrapper is installed on
# the system PATH wherever the pi-chat module is enabled, and launchers
# resolve Exec via PATH, so the entries stay independent of store paths.
{
  pkgs,
  spaces-logos ? pkgs.callPackage ../spaces-logos { },
  ...
}:
let
  inherit (pkgs) lib;

  # Icon palette/geometry: the black-filled mark from the canonical SVG
  # on a white tile. The mark <path/> is still recolored to markColor
  # (a no-op while it stays black) so the palette remains a two-knob
  # switch — keep tileColor and markColor contrasting.
  tileColor = "#ffffff";
  markColor = "#000000";
  tileSize = 512;
  cornerRadius = 100;
  # Mark centered at ~62% tile width; height follows the 252:219 viewBox
  # aspect, so only markWidth needs touching to rescale.
  markWidth = 320;
  markHeight = markWidth * 219 / 252;
  markX = (tileSize - markWidth) / 2;
  markY = (tileSize - markHeight) / 2;

  iconSizes = [
    16
    32
    48
    64
    128
    256
    512
  ];
  largestIconSize = toString (lib.foldl' lib.max 0 iconSizes);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pi-chat-desktop-entries";
  version = "1.0";

  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.copyDesktopItems
    pkgs.librsvg
  ];

  desktopItems = [
    (pkgs.makeDesktopItem {
      name = "pi-chat";
      desktopName = "Pi Chat";
      genericName = "AI agent chat panel";
      comment = "Standalone Quickshell chat panel for the spaces AI agent";
      # `show`, not `toggle`: a launcher click should reveal the panel,
      # never hide an already-open one.
      exec = "pi-chat-toggle show";
      icon = "pi-chat";
      terminal = false;
      categories = [ "Utility" ];
      keywords = [
        "ai"
        "agent"
        "chat"
        "assistant"
        "spaces"
      ];
    })
    (pkgs.makeDesktopItem {
      name = "pi-chat-quick-launch";
      desktopName = "Pi Quick Launch";
      genericName = "AI agent prompt bar";
      comment = "Fire-and-forget prompt bar: type a prompt to launch an agent in the background and get notified on completion";
      exec = "pi-chat-toggle quickLaunch";
      icon = "pi-chat";
      terminal = false;
      categories = [ "Utility" ];
      keywords = [
        "ai"
        "agent"
        "prompt"
        "launcher"
        "spaces"
      ];
    })
  ];

  buildPhase = ''
    runHook preBuild

    # Lift the mark out of the canonical SVG (a single self-closing
    # <path/> element) and recolor it for contrast on the tile.
    mark=$(grep -o '<path[^>]*/>' ${spaces-logos}/spaces-logo.svg \
      | sed 's/fill="black"/fill="${markColor}"/')
    [ -n "$mark" ] || { echo "no <path/> found in spaces-logo.svg" >&2; exit 1; }

    cat > pi-chat.svg <<EOF
    <svg width="${toString tileSize}" height="${toString tileSize}" viewBox="0 0 ${toString tileSize} ${toString tileSize}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${toString tileSize}" height="${toString tileSize}" rx="${toString cornerRadius}" fill="${tileColor}"/>
      <svg x="${toString markX}" y="${toString markY}" width="${toString markWidth}" height="${toString markHeight}" viewBox="0 0 252 219">
        $mark
      </svg>
    </svg>
    EOF

    for size in ${toString iconSizes}; do
      rsvg-convert -w $size -h $size pi-chat.svg -o pi-chat-$size.png
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 pi-chat.svg $out/share/icons/hicolor/scalable/apps/pi-chat.svg
    for size in ${toString iconSizes}; do
      install -Dm644 pi-chat-$size.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/pi-chat.png
    done

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    pkgs.desktop-file-utils
    pkgs.imagemagick
  ];
  installCheckPhase = ''
    runHook preInstallCheck

    fail() {
      echo "installCheck: $1" >&2
      exit 1
    }

    for entry in pi-chat pi-chat-quick-launch; do
      f=$out/share/applications/$entry.desktop
      [ -f "$f" ] || fail "missing desktop entry $f"
      desktop-file-validate "$f" || fail "desktop-file-validate rejected $f"
    done

    [ -f $out/share/icons/hicolor/scalable/apps/pi-chat.svg ] \
      || fail "missing scalable icon"

    for size in ${toString iconSizes}; do
      png=$out/share/icons/hicolor/''${size}x''${size}/apps/pi-chat.png
      [ -f "$png" ] || fail "missing $png"
      dims=$(magick identify -format '%wx%h' "$png")
      [ "$dims" = "''${size}x''${size}" ] \
        || fail "$png is $dims, expected ''${size}x''${size}"
    done

    big=$out/share/icons/hicolor/${largestIconSize}x${largestIconSize}/apps/pi-chat.png
    # Contrast guard. %k (unique colors) catches a fully flat render;
    # the two mean-luminance probes catch the subtler failures: a
    # dropped tile rect flattens to (near) black, and a mark recolored
    # to the tile color flattens to (near) white (corner anti-aliasing
    # keeps %k above 1 in both cases).
    colors=$(magick "$big" -format '%k' info:)
    [ "$colors" -gt 1 ] || fail "icon is a single flat color"
    # -alpha off after -flatten: flatten leaves an opaque alpha channel
    # and %[fx:mean] averages over ALL channels, so an all-black image
    # would otherwise score 0.5 and slip past the threshold.
    mean=$(magick "$big" -background black -flatten -alpha off -colorspace gray \
      -format '%[fx:mean]' info:)
    awk -v m="$mean" 'BEGIN { exit !(m > 0.02) }' \
      || fail "icon is (near) solid black: mean luminance $mean"
    mean=$(magick "$big" -background white -flatten -alpha off -colorspace gray \
      -format '%[fx:mean]' info:)
    awk -v m="$mean" 'BEGIN { exit !(m < 0.98) }' \
      || fail "icon is (near) solid white: mean luminance $mean"

    runHook postInstallCheck
  '';
}
