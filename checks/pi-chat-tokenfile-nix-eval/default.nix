# Cheap nix-eval contract for the pi-chat client-side WS tokenFile — the secret
# indirection that keeps the `hello` token out of the world-readable panel
# config and the Nix store (the server side already has services.pi-sessiond
# .tokenFile; this is its client counterpart). Asserts:
#   - wsTokenFile -> the rendered pi-chat.json executor advertises a `tokenPath`
#     under /run/spaces-secrets and carries NO inline token; the staging service
#     is present and installs the host file to that path.
#   - wsToken     -> the executor carries the inline token (back-compat) and no
#     token-staging service is created.
#   - both set    -> a failed assertion (mutually exclusive).
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  baseModules = [
    {
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      boot.loader.grub.enable = false;
      system.stateVersion = "26.05";
    }
  ];

  mkSystem =
    extra:
    lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ [ inputs.self.nixosModules.pi-chat ] ++ extra;
    };

  common = {
    services.pi-chat.enable = true;
    # Token plumbing only — keep the loopback daemon out of the closure.
    services.pi-chat.localExecutor.enable = false;
    services.pi-chat.wsUrl = "ws://server:8770";
  };

  fileSystem = mkSystem [
    common
    { services.pi-chat.wsTokenFile = "/run/secrets/ws-token"; }
  ];
  inlineSystem = mkSystem [
    common
    { services.pi-chat.wsToken = "inline-secret"; }
  ];
  conflictSystem = mkSystem [
    common
    {
      services.pi-chat.wsToken = "inline-secret";
      services.pi-chat.wsTokenFile = "/run/secrets/ws-token";
    }
  ];

  # The mutual-exclusion assertion is present and tripped (assertion = false)
  # only when both are set — checked without realizing toplevel (which aborts).
  conflictRejected = builtins.any (
    a: !a.assertion && lib.hasInfix "wsToken" a.message
  ) conflictSystem.config.assertions;
in
pkgs.runCommand "pi-chat-tokenfile-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    fileCfg = fileSystem.config.environment.etc."spaces/pi-chat.json".source;
    inlineCfg = inlineSystem.config.environment.etc."spaces/pi-chat.json".source;
    stagingScript = fileSystem.config.systemd.services.spaces-secrets-load.script or "";
    inlineHasStaging =
      if (inlineSystem.config.systemd.services.spaces-secrets-load or null) == null then "no" else "yes";
    conflictRejected = if conflictRejected then "yes" else "no";
  }
  ''
    set -euo pipefail

    # wsTokenFile: the executor advertises a staged tokenPath and no inline token.
    tp=$(jq -r '.executors[0].tokenPath // ""' "$fileCfg")
    tok=$(jq -r '.executors[0].token // ""' "$fileCfg")
    [ "$tp" = "/run/spaces-secrets/pi-chat-token-remote" ] || { echo "FAIL: tokenPath=$tp"; exit 1; }
    [ "$tok" = "" ] || { echo "FAIL: inline token leaked into config: $tok"; exit 1; }

    # The staging service installs the host file to that path (root:users 0640).
    printf '%s' "$stagingScript" | grep -q "/run/secrets/ws-token" \
      || { echo "FAIL: staging service missing source path"; exit 1; }
    printf '%s' "$stagingScript" | grep -q "/run/spaces-secrets/pi-chat-token-remote" \
      || { echo "FAIL: staging service missing dest path"; exit 1; }

    # wsToken (inline): the executor carries the token; no token-staging service.
    itok=$(jq -r '.executors[0].token // ""' "$inlineCfg")
    itp=$(jq -r '.executors[0].tokenPath // ""' "$inlineCfg")
    [ "$itok" = "inline-secret" ] || { echo "FAIL: inline token=$itok"; exit 1; }
    [ "$itp" = "" ] || { echo "FAIL: inline config unexpectedly has tokenPath=$itp"; exit 1; }
    [ "$inlineHasStaging" = "no" ] || { echo "FAIL: inline-only config created a secrets service"; exit 1; }

    # Both set -> the mutually-exclusive assertion fails.
    [ "$conflictRejected" = "yes" ] || { echo "FAIL: token+tokenFile conflict not rejected"; exit 1; }

    echo "OK: wsTokenFile -> tokenPath + staging; inline token back-compat; conflict rejected"
    touch "$out"
  ''
