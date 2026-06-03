{ pkgs, ... }:
# pi-web: the PWA client for a pi-sessiond executor (§12 over WebSocket).
#
# Vanilla TypeScript bundled by Bun — zero npm deps, matching the daemon's
# ethos and keeping the Nix build fully offline. The daemon serves the result
# from SPACES_SESSIOND_PWA_DIR on its own port (same origin as the WS).
let
  # app.ts imports ./reducer, so both must sit in one dir for the bundler.
  src = pkgs.runCommandLocal "pi-web-src" { } ''
    mkdir -p "$out"
    cp ${./app.ts} "$out/app.ts"
    cp ${./reducer.ts} "$out/reducer.ts"
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

    # Bundle the TS entrypoint to app.js (no third-party deps → offline).
    export HOME="$TMPDIR"
    bun build ${src}/app.ts --outfile "$out/app.js" --target browser
  ''
