# pi-chat-extensions — the bundled single-file pi extensions (the de-facto
# package that used to live under modules/nixos/pi-chat/extensions/).
#
# Interface:
#   - passthru.extensions.<name> — ONE tracked store path per extension, ready
#     to be listed in a pi settings.json (bash-confirm, llama-swap-discover,
#     openrouter-proxy, spaces-integrations).
#   - passthru.memory — the memory extension derivation (a directory with
#     index.ts), with the sediment binary path baked in.
#   - $out — a directory with every extension as consumed at runtime, plus the
#     unit tests and the wire JSON they read; checks point their extDir here
#     and run `node --test` against exactly what ships.
{
  pkgs,
  inputs,
  ...
}:
let
  inherit (pkgs) lib;

  # Copy each extension to its OWN tracked store path. A bare `toString` of a
  # flake-relative path embeds the whole-flake `…-source` path, which nix's
  # reference scanner does NOT capture as a runtime dependency of a
  # settings.json naming it — the file would be absent from the consumer's
  # store at runtime and pi would silently skip the extension (the `local`
  # provider never registers). `builtins.path` copies just the one file to a
  # standalone, tracked store path.
  materialize =
    f:
    builtins.path {
      path = f;
      name = baseNameOf (toString f);
    };

  # The gateway↔extension sentinel contract, single-sourced from
  # packages/pi-sessiond/integration-wire.json. The supervisor gateway
  # (integrations.ts) reads that JSON at runtime; the bundled extension is a
  # lone store file that cannot import the gateway module, so its build
  # substitutes the same values into the extension source here.
  piSessiond = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  wire = builtins.fromJSON (builtins.readFile piSessiond.integrationWire);

  # The agent-facing half of the integrations gateway (design §9): registers a
  # forwarding tool per discovered integration tool from the per-session spec
  # the supervisor stages. Inert when no spec / no integrations.
  spacesIntegrations = pkgs.runCommand "spaces-integrations.ts" { } ''
    substitute ${./spaces-integrations.ts} "$out" \
      --replace-fail '@@INTEGRATION_CALL_TITLE@@' ${lib.escapeShellArg wire.callTitle} \
      --replace-fail '@@INTEGRATION_TOOL_SPEC_FILE@@' ${lib.escapeShellArg wire.toolSpecFile}
  '';

  extensions = {
    "bash-confirm" = materialize ./bash-confirm.ts;
    "llama-swap-discover" = materialize ./llama-swap-discover.ts;
    "openrouter-proxy" = materialize ./openrouter-proxy.ts;
    "spaces-integrations" = spacesIntegrations;
  };
in
pkgs.runCommand "pi-chat-extensions"
  {
    passthru = {
      inherit extensions;
      # Memory extension: substitutes the absolute sediment binary path into a
      # single-file pi extension (directory with index.ts).
      memory = pkgs.callPackage ./memory {
        sediment = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.sediment;
      };
    };
  }
  ''
    mkdir -p "$out"
    cp ${extensions."bash-confirm"} "$out/bash-confirm.ts"
    cp ${extensions."llama-swap-discover"} "$out/llama-swap-discover.ts"
    cp ${extensions."openrouter-proxy"} "$out/openrouter-proxy.ts"
    cp ${extensions."spaces-integrations"} "$out/spaces-integrations.ts"
    cp ${piSessiond.integrationWire} "$out/integration-wire.json"
    cp ${./bash-confirm.test.mjs} "$out/bash-confirm.test.mjs"
    cp ${./spaces-integrations.test.mjs} "$out/spaces-integrations.test.mjs"
    # The RAW memory extension source (with its @@SEDIMENT_BIN@@ sentinel):
    # checks that stub the sediment binary substitute it themselves; runtime
    # consumers use passthru.memory instead.
    mkdir -p "$out/memory"
    cp ${./memory/index.ts} "$out/memory/index.ts"
  ''
