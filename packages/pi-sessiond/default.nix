{
  pkgs,
  inputs,
  # The pi build whose SDK the daemon embeds. Parameterized so the NixOS module
  # can pin it to services.pi-chat.piPackage — the daemon's in-process pi is then
  # the exact same build as the desktop's local path uses (no version skew).
  pi ? inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi,
  ...
}:
# pi-sessiond — the remote-pi executor daemon (docs/remote-pi-design.md).
#
# A token-authenticated WebSocket transport (§12) in front of a registry of
# in-process pi sessions. The daemon embeds pi via its SDK
# (@earendil-works/pi-coding-agent), which ships inside the `pi` package at
# lib/node_modules — so main.ts's import resolves from the pinned pi build via a
# node_modules symlink, with no offline npm fetch. bash is sandboxed per command
# through systemd-run (sandbox.ts); read/edit/write run in-process under the
# daemon's own (module-level) confinement.
let
  src = pkgs.runCommandLocal "pi-sessiond-src" { } ''
    mkdir -p "$out"
    cp ${./main.ts} "$out/main.ts"
    cp ${./sandbox.ts} "$out/sandbox.ts"
    cp ${./staging.ts} "$out/staging.ts"
    # Resolve @earendil-works/pi-coding-agent (and its deps) from the pinned pi.
    ln -s ${pi}/lib/node_modules "$out/node_modules"
  '';
in
pkgs.writeShellScriptBin "pi-sessiond" ''
  exec ${pkgs.bun}/bin/bun ${src}/main.ts
''
