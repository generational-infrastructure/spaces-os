# NixOS option → user-unit wiring for the unified pi-sessiond-local executor's
# server/remote knobs (docs/pi-sessiond-per-user-refactor.md §4.2).
#
# pi-sessiond-local is the single executor shape: a desktop loopback default and
# the server's per-user remote executor. This pins the knobs that distinguish
# the two deployments, evaluating three NixOS systems and asserting the
# resulting `systemd.user.services.pi-sessiond-local` unit:
#
#   - desktop (defaults): host 127.0.0.1, firewall closed, the per-login
#     token-gen oneshot present, LoadCredential reads %t/.../token, no inline
#     SPACES_SESSIOND_TOKEN.
#   - server (inline token): host 0.0.0.0, firewall opens the port, NO token-gen
#     oneshot, the token rides the unit env, PWA + peers wired.
#   - server (tokenFile): the token is a LoadCredential of the provisioned file,
#     no token-gen oneshot, no inline env token.
#
# Pure nix-eval + jq. No VM, no quickshell. ~3s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  mkSystem =
    hostName: extraConfig:
    lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = [
        inputs.self.nixosModules.pi-sessiond-local
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          networking.hostName = hostName;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          boot.loader.grub.enable = false;
          system.stateVersion = "26.05";
          # Keep the eval cheap: the sediment memory extension drags a model
          # cache into the closure and is irrelevant to the token/bind knobs.
          services.pi-sessiond-local.memory.enable = false;
        }
        extraConfig
      ];
    };

  desktop = mkSystem "knobs-desktop" {
    services.pi-sessiond-local.enable = true;
  };

  server = mkSystem "knobs-server" {
    services.pi-sessiond-local = {
      enable = true;
      host = "0.0.0.0";
      port = 9999;
      openFirewall = true;
      token = "inline-secret";
      serveWebUi = true;
      peers = [
        {
          id = "a";
          host = "a.pin";
        }
      ];
    };
  };

  serverFile = mkSystem "knobs-server-file" {
    services.pi-sessiond-local = {
      enable = true;
      host = "::";
      openFirewall = true;
      tokenFile = pkgs.writeText "knobs-token" "file-secret";
    };
  };

  unit = system: system.config.systemd.user.services.pi-sessiond-local;
  hasTokenGen = system: system.config.systemd.user.services ? pi-sessiond-local-token;
in
pkgs.runCommand "pi-sessiond-local-knobs-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];

    dHost = (unit desktop).environment.SPACES_SESSIOND_HOST;
    dHasTokenGen = if hasTokenGen desktop then "true" else "false";
    dHasTokenEnv = if (unit desktop).environment ? SPACES_SESSIOND_TOKEN then "true" else "false";
    dLoadCred = builtins.toJSON (unit desktop).serviceConfig.LoadCredential;
    dPorts = builtins.toJSON desktop.config.networking.firewall.allowedTCPPorts;

    sHost = (unit server).environment.SPACES_SESSIOND_HOST;
    sTokenEnv = (unit server).environment.SPACES_SESSIOND_TOKEN;
    sHasTokenGen = if hasTokenGen server then "true" else "false";
    sLoadCred = builtins.toJSON (unit server).serviceConfig.LoadCredential;
    sPwaDir = (unit server).environment.SPACES_SESSIOND_PWA_DIR;
    sPeersFile = (unit server).environment.SPACES_SESSIOND_PEERS_FILE;
    sPorts = builtins.toJSON server.config.networking.firewall.allowedTCPPorts;
    sRequires = builtins.toJSON (unit server).requires;

    fHasTokenGen = if hasTokenGen serverFile then "true" else "false";
    fHasTokenEnv = if (unit serverFile).environment ? SPACES_SESSIOND_TOKEN then "true" else "false";
    fLoadCred = builtins.toJSON (unit serverFile).serviceConfig.LoadCredential;
  }
  ''
    set -euo pipefail

    # ── desktop (defaults) ──────────────────────────────────────────
    [ "$dHost" = "127.0.0.1" ] \
      || { echo "FAIL: desktop host = $dHost (expected 127.0.0.1)"; exit 1; }
    [ "$dHasTokenGen" = "true" ] \
      || { echo "FAIL: desktop missing per-login token-gen oneshot"; exit 1; }
    [ "$dHasTokenEnv" = "false" ] \
      || { echo "FAIL: desktop unexpectedly carries inline SPACES_SESSIOND_TOKEN"; exit 1; }
    echo "$dLoadCred" | jq -e '.[] | select(. == "token:%t/pi-sessiond-local/token")' > /dev/null \
      || { echo "FAIL: desktop LoadCredential = $dLoadCred (missing per-login token)"; exit 1; }
    echo "$dPorts" | jq -e '. | index(8768) | not' > /dev/null \
      || { echo "FAIL: desktop firewall = $dPorts (8768 unexpectedly open)"; exit 1; }

    # ── server (inline token) ───────────────────────────────────────
    [ "$sHost" = "0.0.0.0" ] \
      || { echo "FAIL: server host = $sHost (expected 0.0.0.0)"; exit 1; }
    [ "$sTokenEnv" = "inline-secret" ] \
      || { echo "FAIL: server inline token env = $sTokenEnv"; exit 1; }
    [ "$sHasTokenGen" = "false" ] \
      || { echo "FAIL: server must NOT run the per-login token-gen oneshot"; exit 1; }
    echo "$sLoadCred" | jq -e '[.[] | select(startswith("token:"))] | length == 0' > /dev/null \
      || { echo "FAIL: server inline token leaked into LoadCredential = $sLoadCred"; exit 1; }
    echo "$sRequires" | jq -e '. | index("pi-sessiond-local-token.service") | not' > /dev/null \
      || { echo "FAIL: server still requires the token-gen unit = $sRequires"; exit 1; }
    [ -n "$sPwaDir" ] \
      || { echo "FAIL: server serveWebUi did not set SPACES_SESSIOND_PWA_DIR"; exit 1; }
    [ -n "$sPeersFile" ] \
      || { echo "FAIL: server SPACES_SESSIOND_PEERS_FILE empty"; exit 1; }
    echo "$sPorts" | jq -e '. | index(9999)' > /dev/null \
      || { echo "FAIL: server firewall = $sPorts (missing 9999)"; exit 1; }

    # ── server (tokenFile) ──────────────────────────────────────────
    [ "$fHasTokenGen" = "false" ] \
      || { echo "FAIL: tokenFile server must NOT run the per-login token-gen oneshot"; exit 1; }
    [ "$fHasTokenEnv" = "false" ] \
      || { echo "FAIL: tokenFile server unexpectedly carries inline SPACES_SESSIOND_TOKEN"; exit 1; }
    echo "$fLoadCred" | jq -e '.[] | select(startswith("token:")) | select(endswith("knobs-token"))' > /dev/null \
      || { echo "FAIL: tokenFile server LoadCredential = $fLoadCred (missing provisioned token)"; exit 1; }

    echo "OK: pi-sessiond-local desktop/server token + bind knobs wired"
    touch "$out"
  ''
