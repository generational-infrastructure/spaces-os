{
  pkgs,
  inputs,
  # The pi build whose SDK the daemon embeds. Parameterized so the NixOS module
  # can pin it to services.pi-chat.piPackage — the daemon's in-process pi is then
  # the exact same build as the desktop's local path uses (no version skew).
  pi ? inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi,
  ...
}:
# pi-sessiond — the remote-pi executor *supervisor* (docs/remote-pi-design.md,
# docs/pi-runtime-isolation-refactor.md).
#
# A token-authenticated WebSocket transport (§12) in front of a registry of pi
# sessions. The supervisor runs no model code: it spawns one `pi --mode rpc`
# child per session (SPACES_SESSIOND_PI_BIN) and drives it over a JSON-line pipe
# (rpc-driver.ts). The pi binary + its SDK ship in the `pi` package; main.ts's
# SDK import (model registry / provider discovery, supervisor-side) resolves
# from it via a node_modules symlink. `pi` is re-exported as a passthru attr so
# the NixOS module can point SPACES_SESSIOND_PI_BIN at the exact same build.
let
  src = pkgs.runCommandLocal "pi-sessiond-src" { } ''
    mkdir -p "$out"
    cp ${./main.ts} "$out/main.ts"
    cp ${./rpc-driver.ts} "$out/rpc-driver.ts"
    cp ${./proxy.ts} "$out/proxy.ts"
    cp ${./sandbox.ts} "$out/sandbox.ts"
    cp ${./seccomp-denylist.json} "$out/seccomp-denylist.json"
    cp ${./provider.ts} "$out/provider.ts"
    cp ${./staging.ts} "$out/staging.ts"
    cp ${./integrations.ts} "$out/integrations.ts"
    # Resolve @earendil-works/pi-coding-agent (and its deps) from the pinned pi.
    ln -s ${pi}/lib/node_modules "$out/node_modules"
  '';

  # spaces-landlock-policy: the integration units' ExecStartPre policy
  # generator (modules/nixos/spaces-integrations). It wraps the same
  # buildLandlockPolicy the per-session sandbox uses, so the landlockconfig
  # schema keeps a single emitter. Bundled WITHOUT node_modules: it imports
  # only sandbox.ts (+ its JSON denylist), never the pi SDK, so its closure is
  # just bun — cheap to build and to pull onto an integration host.
  policyCliSrc = pkgs.runCommandLocal "spaces-landlock-policy-src" { } ''
    mkdir -p "$out"
    cp ${./landlock-policy-cli.ts} "$out/landlock-policy-cli.ts"
    cp ${./sandbox.ts} "$out/sandbox.ts"
    cp ${./seccomp-denylist.json} "$out/seccomp-denylist.json"
  '';
  landlockPolicy = pkgs.writeShellScriptBin "spaces-landlock-policy" ''
    exec ${pkgs.bun}/bin/bun ${policyCliSrc}/landlock-policy-cli.ts "$@"
  '';
in
# Re-export `pi` so the module wires SPACES_SESSIOND_PI_BIN to the same build
# the embedded SDK resolves against (no child/supervisor version skew).
(pkgs.writeShellScriptBin "pi-sessiond" ''
  exec ${pkgs.bun}/bin/bun ${src}/main.ts
'').overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit pi landlockPolicy;
    };
  })
