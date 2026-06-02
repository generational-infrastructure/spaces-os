{ pkgs, ... }:
# pi-sessiond — the remote-pi executor daemon (docs/remote-pi-design.md).
#
# A token-authenticated WebSocket transport in front of a registry of
# `pi --mode rpc` subprocesses (one per session): pi's event stream is
# forwarded verbatim inside seq-stamped envelopes, and client commands are
# written to the owning subprocess's stdin.
#
# Run under Bun. Both TypeScript modules (main.ts + sandbox.ts) are assembled
# into a single store dir so Bun can resolve the relative import; zero
# third-party deps means no npm lockfile yet. When the daemon consumes pi's
# exported npm types this grows into a proper buildNpmPackage / bun package.
let
  src = pkgs.runCommandLocal "pi-sessiond-src" { } ''
    mkdir -p "$out"
    cp ${./main.ts} "$out/main.ts"
    cp ${./sandbox.ts} "$out/sandbox.ts"
  '';
in
pkgs.writeShellScriptBin "pi-sessiond" ''
  exec ${pkgs.bun}/bin/bun ${src}/main.ts
''
