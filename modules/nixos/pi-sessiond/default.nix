# pi-sessiond NixOS module — a remote-pi *executor* ("LLM + PI" / Harness).
#
# See docs/remote-pi-design.md. pi-sessiond is the resident, single-user
# daemon that owns a machine's pi sessions: a token-authenticated WebSocket
# listener that spawns one `systemd-run`-sandboxed `pi --mode rpc` subprocess
# per session, stamps + fans pi's event stream out to attached clients, and
# serializes client commands into each subprocess's stdin. The same binary
# runs on the desktop (a local executor on `localhost`) and on the always-on
# server; clients hold a static list of executors and attach over the uniform
# WebSocket transport (no TLS for now — the `hello` token is the only gate;
# §1).
#
# This module is the durable *contract* (option surface + service shape). The
# daemon implementation it runs is `services.pi-sessiond.package`.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pi-sessiond;

  # systemd's $STATE_DIRECTORY is only the *relative* name ("pi-sessiond"),
  # but the daemon hands pi an absolute PI_CODING_AGENT_DIR (pi's cwd is the
  # per-session workdir, not the daemon's), so pass the resolved absolute path.
  stateDir = "/var/lib/pi-sessiond";

  jsonFormat = pkgs.formats.json { };

  # Materialize each extension as its own store object. A bare `toString` of a
  # flake-relative path embeds the whole-flake `…-source` path, which nix's
  # reference scanner does NOT capture as a runtime dependency of settings.json
  # — so the file is absent from the executor's store at runtime and pi
  # silently skips the extension (the `local` provider never registers).
  # `builtins.path` copies just the file to a standalone, tracked store path.
  extPaths = map (e: builtins.path {
    path = e;
    name = baseNameOf (toString e);
  }) cfg.extensions;

  # pi's settings.json: which extensions/provider/model a spawned
  # `pi --mode rpc` starts with. The daemon copies this template into its
  # writable agent dir at startup (pi also writes auth.json / lock dirs there).
  piSettings = jsonFormat.generate "pi-sessiond-settings.json" {
    extensions = map toString extPaths;
    inherit (cfg) defaultProvider defaultModel;
    quietStartup = true;
    enableInstallTelemetry = false;
  };
in
{
  options.services.pi-sessiond = {
    enable = lib.mkEnableOption (
      "pi-sessiond: WebSocket daemon supervising sandboxed `pi --mode rpc` "
      + "subprocesses for one user (a remote-pi executor)"
    );

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
      defaultText = lib.literalExpression "inputs.self.packages.\${system}.pi-sessiond";
      description = "The pi-sessiond daemon package (the WebSocket transport + session registry).";
    };

    piPackage = lib.mkOption {
      type = lib.types.package;
      default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
      defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.pi";
      description = "The pi coding agent package the daemon spawns (one `pi --mode rpc` subprocess per session).";
    };

    executorId = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        Stable identifier for this executor, surfaced to clients. Clients hold
        a static list of executors (id + WS address) and key each session on
        `(executor, sessionId)`; this is the `executor` half.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the WebSocket listener binds. The default keeps a desktop
        executor reachable only on `localhost`; set `"0.0.0.0"` (with
        `openFirewall`) for the always-on server executor that remote clients
        attach to.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8770;
      description = "TCP port for the token-authenticated WebSocket listener.";
    };

    token = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Pre-shared token checked on `hello`. Convenient for tests/dev, but
        lands in the world-readable Nix store — prefer `tokenFile` in
        production. Exactly one of `token` / `tokenFile` must be set.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the pre-shared token, loaded via systemd
        `LoadCredential` (never copied into the store). Exactly one of
        `token` / `tokenFile` must be set.
      '';
    };

    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8012";
      description = ''
        Base URL of this executor's own OpenAI-compatible LLM endpoint (its
        co-located llama-swap), without the /v1 suffix. Inference is
        per-executor: the desktop uses its GPU, the server uses its own.
      '';
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "gemma4:e4b";
      description = "Model a new session selects unless the client overrides it; must be served by `llmUrl`.";
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "pi provider a new session uses unless the client overrides it.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port` in the firewall. Required for remote clients to reach this executor.";
    };

    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ../pi-chat/extensions/llama-swap-discover.ts ];
      defaultText = lib.literalExpression "[ ../pi-chat/extensions/llama-swap-discover.ts ]";
      description = ''
        pi extensions every spawned session loads. Defaults to the bundled
        llama-swap-discover extension so the session's model list is
        discovered from `''${llmUrl}/v1/models`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.token != null) != (cfg.tokenFile != null);
        message = "services.pi-sessiond: set exactly one of `token` or `tokenFile`.";
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.pi-sessiond = {
      description = "pi-sessiond — remote-pi executor (WebSocket transport + sandboxed pi --mode rpc sessions)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        SPACES_SESSIOND_HOST = cfg.host;
        SPACES_SESSIOND_PORT = toString cfg.port;
        SPACES_SESSIOND_EXECUTOR_ID = cfg.executorId;
        SPACES_SESSIOND_DEFAULT_MODEL = cfg.defaultModel;
        SPACES_SESSIOND_DEFAULT_PROVIDER = cfg.defaultProvider;
        LLAMA_SWAP_BASE_URL = cfg.llmUrl;
        PI_BIN = lib.getExe cfg.piPackage;
        SPACES_SESSIOND_PI_SETTINGS = "${piSettings}";
        SPACES_SESSIOND_STATE_DIR = stateDir;
        # Bun (and pi) want a writable HOME for caches.
        HOME = stateDir;
      }
      // lib.optionalAttrs (cfg.token != null) {
        SPACES_SESSIOND_TOKEN = cfg.token;
      };
      serviceConfig = {
        ExecStart = lib.getExe' cfg.package "pi-sessiond";
        Restart = "on-failure";
        RestartSec = 2;
        # Per-session jsonl + the daemon-owned session index live here.
        StateDirectory = "pi-sessiond";
        StateDirectoryMode = "0700";
      }
      // lib.optionalAttrs (cfg.tokenFile != null) {
        # Green reads the token from $CREDENTIALS_DIRECTORY/token.
        LoadCredential = [ "token:${toString cfg.tokenFile}" ];
      };
    };
  };
}
