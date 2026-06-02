{ pkgs, ... }:
# pi-sessiond — the remote-pi executor daemon (docs/remote-pi-design.md).
#
# A token-authenticated WebSocket transport in front of a registry of
# `pi --mode rpc` subprocesses (one per session): pi's event stream is
# forwarded verbatim inside seq-stamped envelopes, and client commands are
# written to the owning subprocess's stdin.
#
# Run under Bun — a single TypeScript entrypoint using Bun's built-in
# WebSocket server with zero third-party deps, so there is no npm lockfile or
# vendoring to carry yet. When the daemon starts consuming pi's exported npm
# types (to drop the shallow-parse seams), this grows into a proper
# buildNpmPackage / bun package.
pkgs.writeShellScriptBin "pi-sessiond" ''
  exec ${pkgs.bun}/bin/bun ${./main.ts}
''
