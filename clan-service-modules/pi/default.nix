# Spaces OS — `pi` clan service.
#
# Two roles, one shared pre-shared token:
#
#   - executor: pi-sessiond ("LLM + PI" Harness). Token-authenticated
#               WebSocket daemon that embeds pi via its SDK (one in-process
#               AgentSession per session, `bash` sandboxed at the tool
#               boundary). See docs/remote-pi-design.md.
#
#   - client:   pi-chat. Quickshell panel that attaches to *every* executor
#               in this instance simultaneously (same-machine over loopback,
#               remote machines over ws://<host>.<meta.domain>:<port>).
#
# A single `<instanceName>-pi-sessiond-token` clan var (share = true) is
# generated once and deployed to every machine in either role — no manual
# token coordination. Address discovery is automatic: the client iterates
# `roles.executor.machines` and builds the right URL per executor (loopback
# for the local one, `meta.domain` for remote ones). The executor binds
# loopback when every assigned client is on the same machine, and dual-stack
# (with the firewall opened) when any client lives elsewhere.
#
# Each executor also runs a co-located llama-swap (the OpenAI-compatible LLM
# endpoint pi-sessiond's `llmUrl` points at), enabled by default — only the GPU
# build and model set are overridden per machine. It is always protected by a
# second instance-shared clan var, `<instanceName>-llama-swap-key` (deployed to
# every member, like the token): pi-sessiond authenticates to its own loopback
# llama-swap with it, and `llamaSwap.openFirewall` (auto-on when a remote member
# exists) exposes the endpoint to the rest of the clan — dual-stack bind + open
# port — for members that want to use it directly. The key, not the network, is
# the gate.
#
# Example inventory entry:
#
#   instances.pi = {
#     module.input = "spaces";   # or whatever input name spaces-os has
#     module.name  = "pi";
#     roles.executor.machines.kiwi   = { };
#     roles.executor.machines.traube = { };
#     roles.client.machines.kiwi     = { };
#   };
{ flake-self }:
{
  _class = "clan.service";

  manifest.name = "pi";
  manifest.description = "Spaces OS pi: pi-sessiond executor (LLM + PI Harness) + pi-chat panel client";
  manifest.categories = [ "AI" ];
  manifest.exports.out = [ "endpoints" ];
  manifest.readme = ''
    Spaces OS `pi` clan service — the remote-pi *executor* (`pi-sessiond`,
    an "LLM + PI" Harness embedding pi via its SDK over a token-auth
    WebSocket) and its *chat panel* (`pi-chat`) — wired together for a
    whole clan in one inventory entry.

    Two roles:

    - **executor**: assign to every machine that should run a local
      pi-sessiond. Auto-binds loopback when every client of this instance
      lives on the same machine, dual-stack (`::`) with the firewall
      opened otherwise. Settings cover port, model defaults, OpenRouter
      opt-in (prompt-backed clan var, no manual API-key plumbing).
      Each executor also runs a co-located llama-swap, always gated by the
      instance-shared `<instanceName>-llama-swap-key` clan var; set
      `llamaSwap.openFirewall` (auto-on with a remote member) to expose that
      endpoint to the rest of the clan at
      `http://<machine>.<meta.domain>:<port>/v1` — the key, not the network,
      is the gate.
    - **client**: assign to every machine that should run the Quickshell
      chat panel. The panel auto-attaches to every executor in the
      instance — same-machine over loopback, remote ones at
      `ws://<machine>.<meta.domain>:<port>` — and the local executor (if
      any) is the default for new sessions.

    A single instance-shared `<instanceName>-pi-sessiond-token` clan var
    (`share = true`) is generated once and deployed to every machine in
    either role: both ends of every link reach the same secret with no
    manual token coordination.

    A second instance-shared clan var, `<instanceName>-llama-swap-key`
    (`share = true`), is generated and deployed the same way: every member
    holds it, each executor requires it on its llama-swap, and the local
    pi-sessiond authenticates with it — so the LLM endpoint is never
    unauthenticated, even before it is exposed off-machine.
  '';

  roles.executor = {
    description = ''
      pi-sessiond — a remote-pi executor ("LLM + PI" Harness): a token-
      authenticated WebSocket daemon that embeds pi via its SDK. Every
      machine assigned the `client` role in this instance attaches to every
      machine assigned `executor`.
    '';

    interface =
      { lib, ... }:
      {
        options = {
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Bind address for the WebSocket listener. `null` (the default)
              auto-picks: `"127.0.0.1"` when every client of this instance
              lives on the same machine (or there are no clients), else
              `"::"` (dual-stack — required so a `<host>.<meta.domain>` that
              resolves to an IPv6 .pin address can be reached).
            '';
          };

          port = lib.mkOption {
            type = lib.types.port;
            default = 8770;
            description = "TCP port the WebSocket listener binds.";
          };

          openFirewall = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = ''
              Open `port` in the firewall. `null` (the default) auto-picks:
              `true` when any client of this instance is a *different*
              machine (so it must reach this executor across the network),
              `false` otherwise.
            '';
          };

          llmUrl = lib.mkOption {
            type = lib.types.str;
            default = "http://127.0.0.1:8012";
            description = ''
              Base URL of this executor's co-located OpenAI-compatible LLM
              endpoint (typically its own `services.llama-swap`), without
              the `/v1` suffix. Inference is per-executor: the desktop uses
              its GPU, the server uses its own.
            '';
          };

          defaultModel = lib.mkOption {
            type = lib.types.str;
            default = "gemma4:e4b";
            description = "Model new sessions select unless the client overrides it.";
          };

          defaultProvider = lib.mkOption {
            type = lib.types.str;
            default = "local";
            description = "pi provider new sessions use unless the client overrides it.";
          };

          executorId = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Stable id surfaced to clients (picker labels read
              `[<id>] <model>`). `null` = use the machine name.
            '';
          };

          openrouter = {
            enable = lib.mkEnableOption ''
              registering the OpenRouter provider in this executor's
              catalog alongside the local provider
            '';
            apiKeyFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                Host path to a file holding the OpenRouter API key; loaded
                via `LoadCredential`, never copied into the store. When
                `enable = true` and this stays `null` (the default), the
                role auto-declares a prompt-backed clan var
                `<instanceName>-openrouter` and wires `apiKeyFile` to it,
                so the user is asked for the key on first deploy and the
                secret never lands in the store. Set explicitly to point
                at an existing secret instead.
              '';
            };
          };

          webUi = {
            enable = lib.mkEnableOption ''
              serving the pi-web PWA from this executor and exposing it
              at a stable clan hostname via a Caddy reverse proxy
            '';
            host = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "agent-foo.pin";
              description = ''
                Hostname the PWA is reachable at when `webUi.enable = true`.
                `null` (the default) auto-derives `agent-<machineName>.<meta.domain>`
                — a per-host convention that scales to several executors
                sharing one clan. The hostname is exported via
                `manifest.exports.endpoints.hosts`, so the `pki` and
                `dm-dns` clan services auto-issue its certificate and
                distribute its CNAME.
              '';
            };
          };

          llamaSwap = {
            webUi = {
              enable = lib.mkEnableOption ''
                exposing the bundled llama-swap web UI on this executor at
                a stable clan hostname via a Caddy reverse proxy
              '';
              host = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "llama-swap.foo.pin";
                description = ''
                  Hostname the llama-swap web UI is reachable at when
                  `llamaSwap.webUi.enable = true`. `null` (the default)
                  auto-derives `llama-swap.<machineName>.<meta.domain>`.
                  The hostname is exported via
                  `manifest.exports.endpoints.hosts`, so the `pki` and
                  `dm-dns` clan services auto-issue its certificate and
                  distribute its CNAME.
                '';
              };
            };

            openFirewall = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = ''
                Expose this executor's llama-swap (its OpenAI-compatible LLM
                endpoint) to the rest of the clan: open its port in the firewall
                and bind it dual-stack (`::`) so members reach it at
                `http://<machine>.<meta.domain>:<port>/v1`. Access is gated by the
                instance-shared `<instanceName>-llama-swap-key` clan var (every
                member holds it; the local pi-sessiond authenticates with it
                too), so the open port is not open to the unauthenticated world.
                `null` (the default) auto-picks: `true` when any client of this
                instance is a *different* machine, `false` otherwise (loopback +
                Docker bridges only). The key is always required regardless.
              '';
            };

            externalConfigFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/var/lib/llama-swap/config.yaml";
              description = ''
                Hand this executor's llama-swap a writable, runtime-editable
                config file instead of the bundled store-pinned catalog.
                `null` (the default) ships the bundled models. Set to a path
                and llama-swap loads it with `-watch-config`, dropping the
                bundled GGUFs from the closure — models are managed at runtime
                by editing the file, no rebuild. Forwards to
                `services.llama-swap.externalConfigFile`; see there for the
                seeding and permission details. Ensure `defaultModel` names a
                model the file actually defines.
              '';
            };
          };
        };
      };

    perInstance =
      {
        settings,
        roles,
        machine,
        meta,
        mkExports,
        instanceName,
        ...
      }:
      let
        effectiveWebUiHost =
          if settings.webUi.host != null then settings.webUi.host else "agent-${machine.name}.${meta.domain}";
        effectiveLlamaSwapHost =
          if settings.llamaSwap.webUi.host != null then
            settings.llamaSwap.webUi.host
          else
            "llama-swap.${machine.name}.${meta.domain}";
      in
      {
        # Endpoint exports — picked up by pinpox's `pki` and `dm-dns` clan
        # services: certs for each host are auto-issued by the local Caddy
        # and CNAMEs are distributed cluster-wide.
        exports = mkExports {
          endpoints.hosts =
            (if settings.webUi.enable then [ effectiveWebUiHost ] else [ ])
            ++ (if settings.llamaSwap.webUi.enable then [ effectiveLlamaSwapHost ] else [ ]);
        };

        nixosModule =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            clientMachines = lib.attrNames (roles.client.machines or { });
            hasRemoteClient = lib.any (n: n != machine.name) clientMachines;

            effectiveHost =
              if settings.host != null then
                settings.host
              else if hasRemoteClient then
                "::"
              else
                "127.0.0.1";

            effectiveFirewall =
              if settings.openFirewall != null then settings.openFirewall else hasRemoteClient;

            # llama-swap exposure mirrors pi-sessiond's: open + dual-stack when a
            # remote member exists, unless overridden. The shared key is required
            # either way (see services.llama-swap.apiKeyEnvFile below).
            effectiveLlamaFirewall =
              if settings.llamaSwap.openFirewall != null then
                settings.llamaSwap.openFirewall
              else
                hasRemoteClient;

            # Every executor in the instance with `webUi.enable = true` — the
            # PWA can only open WS against hosts that have a public Caddy vhost
            # (the browser can't reach loopback-only daemons). Symmetric across
            # the fleet (each peer's pi-sessiond gets the same list) so a chat
            # created on any executor surfaces in any PWA.
            executorMachinesAttrs = roles.executor.machines or { };
            peerNames = lib.naturalSort (
              lib.attrNames (lib.filterAttrs (_: m: m.settings.webUi.enable) executorMachinesAttrs)
            );
            mkPeer =
              name:
              let
                m = executorMachinesAttrs.${name};
              in
              {
                id = if m.settings.executorId == null then name else m.settings.executorId;
                host =
                  if m.settings.webUi.host != null then m.settings.webUi.host else "agent-${name}.${meta.domain}";
              };
            peersList = map mkPeer peerNames;
          in
          {
            imports = [
              # Keyed identically to pi-chat's import so a dual-role machine
              # (executor + client) collapses the two into one module.
              (flake-self.nixosModules.pi-sessiond // { key = "spaces/nixosModules/pi-sessiond"; })
              # llama-swap = the LLM endpoint pi-sessiond.llmUrl points at.
              # Defaults serve gemma4/qwen2.5 on a Vulkan-accelerated llama.cpp
              # at 127.0.0.1:8012 (matching pi-sessiond.llmUrl's default).
              # Per-host overrides — `llama-server-package`, model `settings`,
              # disabling outright — go in that machine's nixos config.
              flake-self.nixosModules.llama-swap
            ];

            services.llama-swap.enable = lib.mkDefault true;
            services.llama-swap.externalConfigFile = settings.llamaSwap.externalConfigFile;

            # Require the instance-shared key on llama-swap. This covers the
            # loopback path the co-located pi-sessiond uses *and* the Docker-bridge
            # path the module already opens — so the endpoint is never
            # unauthenticated, even before it is exposed to the clan. Binding
            # dual-stack (so a `<machine>.<meta.domain>` IPv6 address is reachable)
            # happens only when the firewall is opened for a remote member.
            services.llama-swap.apiKeyEnvFile =
              config.clan.core.vars.generators."${instanceName}-llama-swap-key".files."env".path;
            # `[::]`, not `::`: the upstream services.llama-swap module builds the
            # flag by raw concatenation (`--listen=${listenAddress}:${port}`), so
            # the IPv6 wildcard must be bracketed. Bare `::` yields the invalid
            # `:::8012` ("too many colons in address"), crash-looping the service.
            services.llama-swap.listenAddress = lib.mkIf effectiveLlamaFirewall (lib.mkForce "[::]");

            # Single instance-shared `hello` token. share = true → clan
            # generates the secret once and deploys it to every machine
            # that declares this generator (every executor and every
            # client of this instance). The client role declares an
            # identical twin so the secret reaches both ends without
            # manual coordination.
            clan.core.vars.generators = {
              "${instanceName}-pi-sessiond-token" = {
                share = true;
                files."token" = { };
                runtimeInputs = [ pkgs.openssl ];
                script = ''
                  openssl rand -hex 32 > "$out/token"
                '';
              };
              # Instance-shared llama-swap API key. Two files from one secret:
              # `key` is the raw token (pi-sessiond LoadCredential + any member
              # using the endpoint directly); `env` is an EnvironmentFile
              # (`LLAMA_SWAP_API_KEY=<key>`) for llama-swap itself. share = true →
              # generated once, deployed to every member; the client role declares
              # an identical twin so client-only machines hold it too.
              "${instanceName}-llama-swap-key" = {
                share = true;
                files."key" = { };
                files."env" = { };
                runtimeInputs = [ pkgs.openssl ];
                script = ''
                  key="sk-$(openssl rand -hex 32)"
                  printf '%s' "$key" > "$out/key"
                  printf 'LLAMA_SWAP_API_KEY=%s\n' "$key" > "$out/env"
                '';
              };
            }
            # Auto-declared OpenRouter API-key prompt — used only when
            # the user hasn't supplied an explicit apiKeyFile path.
            // lib.optionalAttrs (settings.openrouter.enable && settings.openrouter.apiKeyFile == null) {
              "${instanceName}-openrouter".prompts."api-key".persist = true;
            };

            # The per-user `--user` executor (docs/pi-sessiond-per-user-refactor.md).
            # No root daemon: this runs in a user manager at that user's own uid.
            # The host provisions the lingering account that runs it (a real user
            # with `users.users.<name>.linger = true`) and makes the token /
            # llama-swap-key clan vars readable by that user — user onboarding is
            # the host action; only integration enablement is on-the-fly. On a
            # dual-role (executor + client) desktop machine the executor *is* the
            # human user's daemon, bound publicly; on a headless executor the host
            # provisions a dedicated lingering user. memory.enable stays off (the
            # prior root executor carried no sediment — keep it out of the server
            # closure).
            services.pi-sessiond = {
              enable = true;
              host = effectiveHost;
              inherit (settings)
                port
                llmUrl
                defaultModel
                defaultProvider
                ;
              openFirewall = effectiveFirewall;
              executorId = if settings.executorId == null then machine.name else settings.executorId;
              tokenFile = config.clan.core.vars.generators."${instanceName}-pi-sessiond-token".files."token".path;
              llmApiKeyFile = config.clan.core.vars.generators."${instanceName}-llama-swap-key".files."key".path;
              openrouter = {
                inherit (settings.openrouter) enable;
                apiKeyFile =
                  if settings.openrouter.apiKeyFile != null then
                    settings.openrouter.apiKeyFile
                  else if settings.openrouter.enable then
                    config.clan.core.vars.generators."${instanceName}-openrouter".files."api-key".path
                  else
                    null;
              };
              serveWebUi = settings.webUi.enable;
              peers = peersList;
              memory.enable = false;
            };

            # Caddy reverse-proxies fronting the executor's two optional
            # clan-hostname endpoints. TLS is terminated by Caddy with the
            # pki-issued cert per host; Caddy 2 passes WS upgrades through
            # verbatim, so the PWA vhost serves the static assets *and*
            # the live WS the PWA opens against same-origin.
            services.caddy = lib.mkIf (settings.webUi.enable || settings.llamaSwap.webUi.enable) {
              enable = true;
              virtualHosts = lib.mkMerge [
                (lib.mkIf settings.webUi.enable {
                  "${effectiveWebUiHost}".extraConfig = "reverse_proxy 127.0.0.1:${toString settings.port}";
                })
                (lib.mkIf settings.llamaSwap.webUi.enable {
                  "${effectiveLlamaSwapHost}".extraConfig =
                    "reverse_proxy 127.0.0.1:${toString config.services.llama-swap.port}";
                })
              ];
            };

            networking.firewall.allowedTCPPorts = lib.mkMerge [
              # Caddy's HTTP(S) ports. 443 is the actual entrypoint; 80 is
              # Caddy's automatic HTTP→HTTPS redirect.
              (lib.mkIf (settings.webUi.enable || settings.llamaSwap.webUi.enable) [
                80
                443
              ])
              # llama-swap, when exposed to the clan (gated by the shared key).
              (lib.mkIf effectiveLlamaFirewall [ config.services.llama-swap.port ])
            ];
          };
      };
  };

  roles.client = {
    description = ''
      pi-chat — the Quickshell chat panel. Auto-attaches to every executor
      (`executor` role) in this instance: same-machine executor over
      loopback, remote ones at `ws://<machine>.<meta.domain>:<port>`. The
      instance's shared token authenticates every connection.
    '';

    interface =
      { lib, ... }:
      {
        options = {
          defaultExecutor = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Executor id new (and legacy un-pinned) sessions are created
              on. Empty = prefer this machine's own executor (if it's also
              assigned the `executor` role), else the first executor by
              machine name.
            '';
          };
        };
      };

    perInstance =
      {
        settings,
        roles,
        machine,
        meta,
        instanceName,
        ...
      }:
      {
        nixosModule =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            executorMachines = roles.executor.machines or { };
            executorNames = lib.naturalSort (lib.attrNames executorMachines);

            tokenPath = config.clan.core.vars.generators."${instanceName}-pi-sessiond-token".files."token".path;

            resolveId = name: m: if m.settings.executorId == null then name else m.settings.executorId;

            mkExecutor =
              name:
              let
                m = executorMachines.${name};
                isLocal = name == machine.name;
              in
              {
                id = resolveId name m;
                url =
                  if isLocal then
                    "ws://127.0.0.1:${toString m.settings.port}"
                  else
                    "ws://${name}.${meta.domain}:${toString m.settings.port}";
                tokenFile = tokenPath;
              };

            executorsList = map mkExecutor executorNames;

            localExecutorId =
              if executorMachines ? ${machine.name} then
                resolveId machine.name executorMachines.${machine.name}
              else
                null;

            chosenDefault =
              if settings.defaultExecutor != "" then
                settings.defaultExecutor
              else if localExecutorId != null then
                localExecutorId
              else if executorsList != [ ] then
                (lib.head executorsList).id
              else
                "";
          in
          {
            imports = [ flake-self.nixosModules.pi-chat ];

            # Identical twin of the executor's generator — declaring it
            # here makes clan deploy the shared token to client-only
            # machines (no executor role) too. NixOS module merging
            # collapses duplicate definitions on dual-role machines.
            clan.core.vars.generators."${instanceName}-pi-sessiond-token" = {
              share = true;
              files."token" = { };
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -hex 32 > "$out/token"
              '';
            };

            # Identical twin of the executor's llama-swap-key generator, so
            # client-only members also hold the shared key — enough to use a
            # remote executor's llama-swap directly. Merges with the executor's
            # definition on dual-role machines.
            clan.core.vars.generators."${instanceName}-llama-swap-key" = {
              share = true;
              files."key" = { };
              files."env" = { };
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                key="sk-$(openssl rand -hex 32)"
                printf '%s' "$key" > "$out/key"
                printf 'LLAMA_SWAP_API_KEY=%s\n' "$key" > "$out/env"
              '';
            };

            services.pi-chat = {
              enable = true;
              executors = executorsList;
              defaultExecutor = chosenDefault;
              # The clan instance owns the executor inventory — machines
              # with the executor role already provide their loopback via
              # the system pi-sessiond, so the panel's own per-user
              # loopback daemon stays off.
              localExecutor.enable = lib.mkDefault false;
            };
          };
      };
  };
}
