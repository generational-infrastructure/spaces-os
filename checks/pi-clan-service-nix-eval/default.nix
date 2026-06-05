# Cheap nix-eval contract for the `pi` clan service. Drives the service's
# `roles.<r>.perInstance` exactly the way clan-core would, with a synthetic
# inventory of:
#
#   kiwi   = executor + client
#   traube = executor only  (kiwi's client attaches to it remotely)
#
# Asserts the wiring outputs we promise users who "just assign roles":
#
#   - kiwi exec   → 127.0.0.1, firewall closed   (every client is local)
#   - traube exec → "::" dual-stack, firewall open (a remote client exists)
#   - kiwi client → executors list contains kiwi (loopback) + traube
#                   (ws://traube.<meta.domain>:8770); defaultExecutor = "kiwi"
#   - both ends point at the same shared token file
#
# Pulls in inputs.self.clan.modules.pi and mimics clan-core's deferredModule
# evaluation locally so the check can run without dragging in clan-core.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  serviceModule = inputs.self.clan.modules.pi;

  meta = {
    name = "test-clan";
    domain = "pin";
  };

  # Mimic clan-core's perInstance schema (deferredModuleWith staticModules)
  # so the lambda's `nixosModule = …` ends up readable as `.config.nixosModule`.
  evalPerInstance =
    lambda: specialArgs:
    (lib.evalModules {
      inherit specialArgs;
      modules = [
        (
          { lib, ... }:
          {
            options.nixosModule = lib.mkOption {
              type = lib.types.deferredModule;
              default = { };
            };
            options.darwinModule = lib.mkOption {
              type = lib.types.deferredModule;
              default = { };
            };
            options.exports = lib.mkOption {
              type = lib.types.lazyAttrsOf lib.types.deferredModule;
              default = { };
            };
          }
        )
        lambda
      ];
    }).config;

  # Mimic clan-core's interface eval — yields resolved-default settings.
  evalSettings =
    interface: userOverrides:
    (lib.evalModules {
      specialArgs = { inherit meta; };
      modules = [
        interface
        { config = userOverrides; }
      ];
    }).config;

  execDefaults = evalSettings serviceModule.roles.executor.interface { };
  clientDefaults = evalSettings serviceModule.roles.client.interface { };

  rolesOnInstance = {
    executor = {
      settings = execDefaults;
      machines = {
        kiwi.settings = execDefaults;
        traube.settings = execDefaults;
      };
    };
    client = {
      settings = clientDefaults;
      machines = {
        kiwi.settings = clientDefaults;
      };
    };
  };

  mkRoleModule =
    roleName: machineName:
    (evalPerInstance serviceModule.roles.${roleName}.perInstance {
      instanceName = "pi";
      machine = {
        name = machineName;
        roles = lib.attrNames (lib.filterAttrs (_: r: r.machines ? ${machineName}) rolesOnInstance);
      };
      inherit (rolesOnInstance.${roleName}.machines.${machineName}) settings;
      roles = rolesOnInstance;
      inherit meta;
    }).nixosModule;

  # Stub the slice of `clan.core.vars.generators` that pi-sessiond / pi-chat /
  # our service read at NixOS-eval time. We only need `.files.<f>.path` to be
  # a string. Stays a private leaf of the test — clan-core itself is not pulled
  # in.
  clanCoreStub =
    { lib, ... }:
    {
      options.clan.core.vars.generators = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            let
              genName = name;
            in
            {
              options.share = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
              options.script = lib.mkOption {
                type = lib.types.str;
                default = "";
              };
              options.runtimeInputs = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
              options.files = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule (
                    { name, ... }:
                    {
                      options.path = lib.mkOption {
                        type = lib.types.str;
                        default = "/run/secrets/vars/${genName}/${name}";
                      };
                    }
                  )
                );
                default = { };
              };
            }
          )
        );
        default = { };
      };
    };

  baseModules = [
    clanCoreStub
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
      modules = baseModules ++ extra;
    };

  kiwiSystem = mkSystem [
    (mkRoleModule "executor" "kiwi")
    (mkRoleModule "client" "kiwi")
  ];

  traubeSystem = mkSystem [
    (mkRoleModule "executor" "traube")
  ];

  kiwiSessiond = kiwiSystem.config.services.pi-sessiond;
  kiwiChat = kiwiSystem.config.services.pi-chat;
  traubeSessiond = traubeSystem.config.services.pi-sessiond;
in
pkgs.runCommand "pi-clan-service-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];

    kiwiSessiondHost = kiwiSessiond.host;
    kiwiSessiondPort = toString kiwiSessiond.port;
    kiwiSessiondId = kiwiSessiond.executorId;
    kiwiSessiondFirewall = if kiwiSessiond.openFirewall then "true" else "false";
    kiwiTokenFile = toString kiwiSessiond.tokenFile;
    kiwiDefaultExecutor = kiwiChat.defaultExecutor;
    kiwiExecutors = builtins.toJSON kiwiChat.executors;

    traubeSessiondHost = traubeSessiond.host;
    traubeSessiondFirewall = if traubeSessiond.openFirewall then "true" else "false";
    traubeSessiondId = traubeSessiond.executorId;
    traubeTokenFile = toString traubeSessiond.tokenFile;
  }
  ''
    set -euo pipefail

    # Kiwi executor: client-only-on-same-machine → loopback + firewall closed.
    [ "$kiwiSessiondHost" = "127.0.0.1" ] \
      || { echo "FAIL: kiwi exec host = $kiwiSessiondHost (expected 127.0.0.1)"; exit 1; }
    [ "$kiwiSessiondPort" = "8770" ] \
      || { echo "FAIL: kiwi exec port = $kiwiSessiondPort"; exit 1; }
    [ "$kiwiSessiondId" = "kiwi" ] \
      || { echo "FAIL: kiwi executorId = $kiwiSessiondId"; exit 1; }
    [ "$kiwiSessiondFirewall" = "false" ] \
      || { echo "FAIL: kiwi exec firewall = $kiwiSessiondFirewall (expected false)"; exit 1; }
    echo "$kiwiTokenFile" | grep -q "pi-pi-sessiond-token" \
      || { echo "FAIL: kiwi tokenFile = $kiwiTokenFile"; exit 1; }

    # Kiwi client: defaultExecutor = local; kiwi (loopback) + traube
    # (via meta.domain) both listed; both share the same token file.
    [ "$kiwiDefaultExecutor" = "kiwi" ] \
      || { echo "FAIL: kiwi defaultExecutor = $kiwiDefaultExecutor"; exit 1; }

    printf '%s' "$kiwiExecutors" > exec.json
    jq -e '.[] | select(.id == "kiwi") | select(.url == "ws://127.0.0.1:8770")' exec.json > /dev/null \
      || { echo "FAIL: kiwi loopback executor entry missing"; cat exec.json; exit 1; }
    jq -e '.[] | select(.id == "traube") | select(.url == "ws://traube.pin:8770")' exec.json > /dev/null \
      || { echo "FAIL: traube remote executor entry missing"; cat exec.json; exit 1; }
    # Same shared token file on both sides of the link.
    clientTok=$(jq -r '.[] | select(.id == "traube") | .tokenFile' exec.json)
    [ "$clientTok" = "$traubeTokenFile" ] \
      || { echo "FAIL: client traube tokenFile=$clientTok != traube tokenFile=$traubeTokenFile"; exit 1; }

    # Traube executor (remote, kiwi is the client): dual-stack bind + firewall
    # opened automatically.
    [ "$traubeSessiondHost" = "::" ] \
      || { echo "FAIL: traube exec host = $traubeSessiondHost (expected ::)"; exit 1; }
    [ "$traubeSessiondFirewall" = "true" ] \
      || { echo "FAIL: traube exec firewall = $traubeSessiondFirewall (expected true)"; exit 1; }
    [ "$traubeSessiondId" = "traube" ] \
      || { echo "FAIL: traube executorId = $traubeSessiondId"; exit 1; }

    echo "OK: kiwi (loopback exec + client) + traube (dual-stack exec) auto-wired"
    touch "$out"
  ''
