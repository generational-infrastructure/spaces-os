{ pkgs, ... }:
# pi-web: the PWA client for a pi-sessiond executor (§12 over WebSocket).
#
# Vanilla TypeScript bundled by Bun — zero npm deps, matching the daemon's
# ethos and keeping the Nix build fully offline. The daemon serves the result
# from SPACES_SESSIOND_PWA_DIR on its own port (same origin as the WS).
#
# Visual language is the Spaces OS design system (vendored token CSS + Tabler
# icon SVGs under ./design/, linked from index.html). The DOM is a vanilla-TS
# translation of the design system's PWA UI kit (two-view list → chat with the
# machine-aware runtime control). The original handoff bundle (HTML/CSS/JSX
# kits, tokens, components, transcripts) is preserved verbatim under
# docs/design-system/source/ as the design source of truth.
let
  # app.ts imports ./reducer and ../pi-sessiond/protocol (the shared §12 wire
  # module — ONE source file, referenced across the package boundary by nix
  # path, so there is no second copy to keep in sync). Recreate that relative
  # layout for the bundler.
  src = pkgs.runCommandLocal "pi-web-src" { } ''
    mkdir -p "$out/pi-web" "$out/pi-sessiond"
    cp ${./app.ts} "$out/pi-web/app.ts"
    cp ${./reducer.ts} "$out/pi-web/reducer.ts"
    cp ${../pi-sessiond/protocol.ts} "$out/pi-sessiond/protocol.ts"
  '';
in
pkgs.runCommandLocal "pi-web"
  {
    nativeBuildInputs = [ pkgs.bun ];
  }
  ''
    mkdir -p "$out"
    cp ${./index.html} "$out/index.html"
    cp ${./manifest.webmanifest} "$out/manifest.webmanifest"
    cp ${./sw.js} "$out/sw.js"
    cp ${./icon.svg} "$out/icon.svg"

    # Vendored design system (tokens + Tabler icon SVGs); see ./design/styles.css.
    cp -r ${./design} "$out/design"
    chmod -R u+w "$out/design"

    # Bundle the TS entrypoint to app.js (no third-party deps → offline).
    export HOME="$TMPDIR"
    bun build ${src}/pi-web/app.ts --outfile "$out/app.js" --target browser
  ''
