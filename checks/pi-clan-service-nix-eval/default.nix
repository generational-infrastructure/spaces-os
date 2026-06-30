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
  traubeOverrides = evalSettings serviceModule.roles.executor.interface {
    webUi.enable = true;
  };
  clientDefaults = evalSettings serviceModule.roles.client.interface { };

  rolesOnInstance = {
    executor = {
      settings = execDefaults;
      machines = {
        kiwi.settings = execDefaults;
        traube.settings = traubeOverrides;
      };
    };
    client = {
      settings = clientDefaults;
      machines = {
        kiwi.settings = clientDefaults;
      };
    };
  };

  # Stub mkExports — clan-core uses a scope-key wrapper for dedupe across
  # roles × machines × instances; our test never reads .exports, so a
  # minimal per-machine wrapper is enough to satisfy the option type.
  mkExportsStub = machineName: v: { ${machineName} = v; };

  mkRoleConfig =
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
      mkExports = mkExportsStub machineName;
    });

  mkRoleModule = roleName: machineName: (mkRoleConfig roleName machineName).nixosModule;

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
  traubeCaddy = traubeSystem.config.services.caddy;
  kiwiCaddy = kiwiSystem.config.services.caddy;
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

    traubeServeWebUi = if traubeSessiond.serveWebUi then "true" else "false";
    traubeCaddyEnabled = if traubeCaddy.enable then "true" else "false";
    traubeCaddyVhosts = builtins.toJSON (lib.attrNames (traubeCaddy.virtualHosts or { }));
    traubeOpenPorts = builtins.toJSON traubeSystem.config.networking.firewall.allowedTCPPorts;

    kiwiServeWebUi = if kiwiSessiond.serveWebUi then "true" else "false";
    kiwiCaddyEnabled = if kiwiCaddy.enable then "true" else "false";
    kiwiOpenPorts = builtins.toJSON kiwiSystem.config.networking.firewall.allowedTCPPorts;

    # llama-swap shared-key auth + clan exposure.
    llamaKeyShare =
      if kiwiSystem.config.clan.core.vars.generators."pi-llama-swap-key".share then "true" else "false";
    llamaKeyFiles = builtins.toJSON (
      lib.attrNames kiwiSystem.config.clan.core.vars.generators."pi-llama-swap-key".files
    );
    kiwiLlamaApiKeys = builtins.toJSON kiwiSystem.config.services.llama-swap.settings.apiKeys;
    kiwiLlamaEnvFile = builtins.toJSON kiwiSystem.config.systemd.services.llama-swap.serviceConfig.EnvironmentFile;
    kiwiLlamaListen = kiwiSystem.config.services.llama-swap.listenAddress;
    kiwiLlmApiKeyFile = toString kiwiSessiond.llmApiKeyFile;
    traubeLlamaListen = traubeSystem.config.services.llama-swap.listenAddress;
    traubeLlmApiKeyFile = toString traubeSessiond.llmApiKeyFile;

    # Per-user model: each executor is a `--user` service, no root daemon.
    kiwiUserUnit = if kiwiSystem.config.systemd.user.services ? pi-sessiond then "true" else "false";
    kiwiNoRootDaemon = if kiwiSystem.config.systemd.services ? pi-sessiond then "false" else "true";
    traubeUserUnit =
      if traubeSystem.config.systemd.user.services ? pi-sessiond then "true" else "false";
    traubeNoRootDaemon = if traubeSystem.config.systemd.services ? pi-sessiond then "false" else "true";
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

    # Per-user model: each executor is a systemd `--user` service at the user's
    # own uid — no root systemd.services.pi-sessiond daemon survives.
    # docs/pi-sessiond-per-user-refactor.md.
    [ "$kiwiUserUnit" = "true" ] \
      || { echo "FAIL: kiwi has no systemd.user.services.pi-sessiond"; exit 1; }
    [ "$kiwiNoRootDaemon" = "true" ] \
      || { echo "FAIL: kiwi still defines a root systemd.services.pi-sessiond"; exit 1; }
    [ "$traubeUserUnit" = "true" ] \
      || { echo "FAIL: traube has no systemd.user.services.pi-sessiond"; exit 1; }
    [ "$traubeNoRootDaemon" = "true" ] \
      || { echo "FAIL: traube still defines a root systemd.services.pi-sessiond"; exit 1; }

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

    # Traube PWA: webUi.enable = true → serveWebUi + Caddy reverse-proxy
    # at the auto-derived `agent-traube.<meta.domain>` hostname, exported
    # so pinpox's pki + dm-dns services pick it up.
    [ "$traubeServeWebUi" = "true" ] \
      || { echo "FAIL: traube serveWebUi = $traubeServeWebUi"; exit 1; }
    [ "$traubeCaddyEnabled" = "true" ] \
      || { echo "FAIL: traube services.caddy.enable = $traubeCaddyEnabled"; exit 1; }
    echo "$traubeCaddyVhosts" | jq -e '. | index("agent-traube.pin")' > /dev/null \
      || { echo "FAIL: traube caddy vhosts = $traubeCaddyVhosts"; exit 1; }
    # Caddy's HTTP(S) ports must be in traube's firewall — without them
    # the vhost above is unreachable from anywhere off-machine.
    echo "$traubeOpenPorts" | jq -e '. | index(80)' > /dev/null \
      || { echo "FAIL: traube firewall open ports = $traubeOpenPorts (missing 80)"; exit 1; }
    echo "$traubeOpenPorts" | jq -e '. | index(443)' > /dev/null \
      || { echo "FAIL: traube firewall open ports = $traubeOpenPorts (missing 443)"; exit 1; }

    # Kiwi has webUi.enable = false (default) — neither serveWebUi nor
    # Caddy gets wired up by the role on this machine, and the firewall
    # stays closed for 80/443.
    [ "$kiwiServeWebUi" = "false" ] \
      || { echo "FAIL: kiwi serveWebUi = $kiwiServeWebUi (expected false)"; exit 1; }
    [ "$kiwiCaddyEnabled" = "false" ] \
      || { echo "FAIL: kiwi caddy enabled = $kiwiCaddyEnabled (expected false)"; exit 1; }
    echo "$kiwiOpenPorts" | jq -e '. | index(443) | not' > /dev/null \
      || { echo "FAIL: kiwi firewall open ports = $kiwiOpenPorts (443 unexpectedly open)"; exit 1; }

    # ── llama-swap shared-key auth + clan exposure ──────────────────
    # One shared generator: raw `key` (pi-sessiond + members using the endpoint
    # directly) and an `env` EnvironmentFile (llama-swap itself).
    [ "$llamaKeyShare" = "true" ] \
      || { echo "FAIL: llama-swap-key generator not shared"; exit 1; }
    echo "$llamaKeyFiles" | jq -e '. | index("key")' > /dev/null \
      || { echo "FAIL: llama-swap-key files = $llamaKeyFiles (missing key)"; exit 1; }
    echo "$llamaKeyFiles" | jq -e '. | index("env")' > /dev/null \
      || { echo "FAIL: llama-swap-key files = $llamaKeyFiles (missing env)"; exit 1; }

    # Executor llama-swap requires the key: apiKeys references the env macro and
    # EnvironmentFile points at the generator's `env` file.
    echo "$kiwiLlamaApiKeys" | grep -q 'env.LLAMA_SWAP_API_KEY' \
      || { echo "FAIL: kiwi llama-swap apiKeys = $kiwiLlamaApiKeys"; exit 1; }
    echo "$kiwiLlamaEnvFile" | jq -e '.[] | select(endswith("pi-llama-swap-key/env"))' > /dev/null \
      || { echo "FAIL: kiwi llama-swap EnvironmentFile = $kiwiLlamaEnvFile"; exit 1; }
    # pi-sessiond authenticates to its loopback llama-swap with the raw key;
    # both executors point at the same shared file.
    echo "$kiwiLlmApiKeyFile" | grep -q "pi-llama-swap-key/key" \
      || { echo "FAIL: kiwi pi-sessiond llmApiKeyFile = $kiwiLlmApiKeyFile"; exit 1; }
    [ "$traubeLlmApiKeyFile" = "$kiwiLlmApiKeyFile" ] \
      || { echo "FAIL: traube llmApiKeyFile=$traubeLlmApiKeyFile != kiwi=$kiwiLlmApiKeyFile"; exit 1; }

    # Exposure: kiwi (no remote member) stays loopback/bridge-only — llama port
    # closed, bind unforced (0.0.0.0). traube (kiwi attaches remotely) opens the
    # port and binds dual-stack so traube.pin is reachable.
    [ "$kiwiLlamaListen" = "0.0.0.0" ] \
      || { echo "FAIL: kiwi llama listenAddress = $kiwiLlamaListen (expected 0.0.0.0)"; exit 1; }
    echo "$kiwiOpenPorts" | jq -e '. | index(8012) | not' > /dev/null \
      || { echo "FAIL: kiwi firewall = $kiwiOpenPorts (8012 unexpectedly open)"; exit 1; }
    [ "$traubeLlamaListen" = "[::]" ] \
      || { echo "FAIL: traube llama listenAddress = $traubeLlamaListen (expected [::])"; exit 1; }
    echo "$traubeOpenPorts" | jq -e '. | index(8012)' > /dev/null \
      || { echo "FAIL: traube firewall = $traubeOpenPorts (missing 8012)"; exit 1; }

    echo "OK: kiwi (loopback exec + client) + traube (dual-stack exec + PWA at agent-traube.pin) auto-wired"
    touch "$out"
  ''
