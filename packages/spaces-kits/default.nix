{ pkgs, ... }:
# spaces-kits: the Spaces OS flagship UI kits (Files + Arlo home) rendered as
# real, browsable screens.
#
# Vanilla TypeScript bundled by Bun — zero npm deps, fully offline, matching
# packages/pi-web's ethos. Each kit is a DOM-building translation of the Kin
# design system's React/JSX source: ./lib holds the ported design-system
# primitives (Button, Input, FileTile, Avatar, ArloOrb, …) and the two kits
# under ./files and ./home compose them into a screen.
#
# Visual language is the native Kin design system (vendored token CSS + the
# Kin mark under ./design/). Output layout:
#   index.html            landing page linking both kits
#   files/  home/         each: index.html + bundled app.js
#   design/               styles.css + tokens + assets
let
  # Bun resolves the kits' `../lib/*` imports, so the whole TS tree must sit
  # together in one source dir for the bundler.
  src = pkgs.runCommandLocal "spaces-kits-src" { } ''
    mkdir -p "$out/lib" "$out/files" "$out/home"
    cp ${./lib/dom.ts}        "$out/lib/dom.ts"
    cp ${./lib/icon.ts}       "$out/lib/icon.ts"
    cp ${./lib/components.ts} "$out/lib/components.ts"
    cp ${./files/main.ts}     "$out/files/main.ts"
    cp ${./home/main.ts}      "$out/home/main.ts"
  '';
in
pkgs.runCommandLocal "spaces-kits"
  {
    nativeBuildInputs = [ pkgs.bun ];
  }
  ''
    mkdir -p "$out/files" "$out/home"
    cp ${./index.html}       "$out/index.html"
    cp ${./files/index.html} "$out/files/index.html"
    cp ${./home/index.html}  "$out/home/index.html"

    # Vendored native Kin design system (tokens + the Kin mark).
    cp -r ${./design} "$out/design"
    chmod -R u+w "$out/design"

    # Bundle each kit entrypoint to its own app.js (no third-party deps → offline).
    export HOME="$TMPDIR"
    bun build ${src}/files/main.ts --outfile "$out/files/app.js" --target browser
    bun build ${src}/home/main.ts  --outfile "$out/home/app.js"  --target browser
  ''
