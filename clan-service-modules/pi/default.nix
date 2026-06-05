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
# Llama-swap (the LLM endpoint pi-sessiond's `llmUrl` points at) is *not*
# bundled — it's hardware-specific (GPU build, model set) and belongs in
# each executor's machine config alongside the rest of its inference setup.
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
    - **client**: assign to every machine that should run the Quickshell
      chat panel. The panel auto-attaches to every executor in the
      instance — same-machine over loopback, remote ones at
      `ws://<machine>.<meta.domain>:<port>` — and the local executor (if
      any) is the default for new sessions.

    A single instance-shared `<instanceName>-pi-sessiond-token` clan var
    (`share = true`) is generated once and deployed to every machine in
    either role: both ends of every link reach the same secret with no
    manual token coordination.
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
        };
      };

    perInstance =
      {
        settings,
        roles,
        machine,
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
          in
          {
            imports = [
              flake-self.nixosModules.pi-sessiond
              # llama-swap = the LLM endpoint pi-sessiond.llmUrl points at.
              # Defaults serve gemma4/qwen2.5 on a Vulkan-accelerated llama.cpp
              # at 127.0.0.1:8012 (matching pi-sessiond.llmUrl's default).
              # Per-host overrides — `llama-server-package`, model `settings`,
              # disabling outright — go in that machine's nixos config.
              flake-self.nixosModules.llama-swap
            ];

            services.llama-swap.enable = lib.mkDefault true;

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
            }
            # Auto-declared OpenRouter API-key prompt — used only when
            # the user hasn't supplied an explicit apiKeyFile path.
            // lib.optionalAttrs (settings.openrouter.enable && settings.openrouter.apiKeyFile == null) {
              "${instanceName}-openrouter".prompts."api-key".persist = true;
            };

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
            };
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

            services.pi-chat = {
              enable = true;
              executors = executorsList;
              defaultExecutor = chosenDefault;
            };
          };
      };
  };
}
