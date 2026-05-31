# Solid-color wallpaper with a distinctive OCR marker text.
#
# Used by the test-support module to give niri a deterministic
# wallpaper that VM tests can detect via tesseract OCR — proves
# the compositor actually rendered something rather than just
# starting up.
#
# Output: $out/wallpaper.png (1280x800, white text on dark background).
{ pkgs, ... }:
pkgs.runCommand "test-wallpaper"
  {
    nativeBuildInputs = [ pkgs.imagemagick ];
    fontFile = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";
  }
  ''
    mkdir -p $out
    # Tile "NIRI TEST OK" across the whole screen so OCR is highly
    # likely to detect at least one instance even with rendering noise.
    magick \
      -size 1280x800 \
      xc:'#000000' \
      -gravity northwest \
      -fill '#ffffff' \
      -stroke '#000000' \
      -strokewidth 3 \
      -font "$fontFile" \
      -pointsize 64 \
      $(for row in $(seq 0 5); do
          y=$((row * 130 + 30))
          for col in 0 1; do
            x=$((col * 640 + 20))
            echo "-annotate +$x+$y SPACES_TEST_OK"
          done
        done) \
      $out/wallpaper.png
  ''
