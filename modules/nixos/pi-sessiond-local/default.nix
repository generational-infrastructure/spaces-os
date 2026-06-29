# pi-sessiond-local — the per-user `--user` pi-sessiond executor.
#
# The single executor shape, run as a systemd *user* service in the user's own
# manager at the user's own uid. Two deployments, one module:
#   - desktop: loopback (host 127.0.0.1), a per-login random token the panel
#     reads locally, dies at logout.
#   - server:  a remote linger-enabled user binds publicly (host "0.0.0.0"/"::"
#     + openFirewall) with an explicit provisioned token/tokenFile a remote
#     client holds; linger keeps it up without a login.
#
# The daemon runs as the user, hardened with ProtectHome=tmpfs so the supervisor
# (and any in-process extension) never sees $HOME; each per-session pi child is
# spawned through the Landlock launcher (pi-landlock-exec), which applies a
# self-applied, deny-by-default Landlock domain (FS allowlist + egress port
# allowlist + IPC scoping) plus a seccomp denylist before exec'ing pi
# (docs/landlock-sandbox-design.md). Cross-user isolation on a server is plain
# DAC: distinct real uids, 0700 state dirs, user-scoped credentials.
#
# Auth: with neither `token` nor `tokenFile` set (the desktop default) a oneshot
# sibling unit generates a per-login token at
# $XDG_RUNTIME_DIR/pi-sessiond-local/token (0600); the daemon reads it via
# LoadCredential and the panel reads the same file directly — no secret touches
# the store. A server sets `token` (dev/test; lands in the store) or `tokenFile`
# (LoadCredential) to a provisioned secret instead.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pi-sessiond-local;

  sessiondLib = import ./lib.nix { inherit pkgs lib inputs; };
  inherit (sessiondLib) jsonFormat landlockExec;

  # Long-term memory (sediment) — same store the local spawn pattern used
  # (~/.local/state/spaces/pi/sediment), so memories persist across the
  # executor switch. The extension runs in-process, so the *daemon*
  # namespace gets the DB bind; the sandboxed pi children never see it.
  sedimentPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.sediment;
  memoryExtensionPkg = pkgs.callPackage ../pi-chat/extensions/memory { sediment = sedimentPkg; };
  memoryDbRel = ".local/state/spaces/pi/sediment";

  child = sessiondLib.mkChild {
    inherit (cfg)
      package
      defaultProvider
      defaultModel
      extensions
      ;
    name = "pi-sessiond-local";
    extra = lib.optional cfg.memory.enable memoryExtensionPkg;
    openrouter = cfg.openrouter.enable;
    baseSettings = cfg.piSettings;
    ownedSettings = {
      skills = lib.attrValues cfg.skills;
    };
  };
  inherit (child) piBin piSettings;

  # bash-confirm allow-list, staged into the daemon's agent dir at boot
  # (the extension reads $PI_CODING_AGENT_DIR/bash-confirm.json).
  bashConfirmJson = jsonFormat.generate "pi-sessiond-local-bash-confirm.json" {
    inherit (cfg.bashConfirm) allowPatterns;
  };

  # The per-session pi units must land in the *user* manager, not the system
  # one — wrap systemd-run so the daemon's every invocation carries --user.
  systemdRunUser = pkgs.writeShellScript "pi-sessiond-local-systemd-run" ''
    exec ${pkgs.systemd}/bin/systemd-run --user "$@"
  '';

  # Idempotent per-login token: keep an existing non-empty file so daemon
  # restarts within one login session don't invalidate attached clients.
  tokenScript = pkgs.writeShellScript "pi-sessiond-local-gen-token" ''
    umask 077
    f="$XDG_RUNTIME_DIR/pi-sessiond-local/token"
    [ -s "$f" ] || ${pkgs.openssl}/bin/openssl rand -hex 32 > "$f"
  '';

  # Fleet topology surfaced to PWA clients via GET /executors (see main.ts
  # loadPeers). Materialized as a tracked store path so nix pins it to the unit.
  peersFile = jsonFormat.generate "pi-sessiond-local-peers.json" cfg.peers;

  # Desktop default: with no provisioned token, generate a per-login random one
  # (the panel reads the same file). A server sets token/tokenFile instead.
  useGeneratedToken = cfg.token == null && cfg.tokenFile == null;
in
{
  options.services.pi-sessiond-local = {
    enable = lib.mkEnableOption (
      "pi-sessiond-local: the per-user `--user` pi-sessiond executor — the "
      + "desktop's loopback default and the server's per-user remote executor"
    );

    package = lib.mkOption {
      type = lib.types.package;
      default = import ../../../packages/pi-sessiond { inherit pkgs inputs; };
      defaultText = lib.literalExpression "import ../../../packages/pi-sessiond { inherit pkgs inputs; }";
      description = "The pi-sessiond daemon package (the WebSocket transport + session registry).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8768;
      description = "Loopback TCP port for the token-authenticated WebSocket listener.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the WebSocket listener binds. The default keeps a desktop
        executor reachable only on `localhost`; a server user sets
        `"0.0.0.0"`/`"::"` (with `openFirewall`) so remote clients attach.
      '';
    };

    openFirewall = lib.mkEnableOption "opening `port` in the firewall (a server executor reachable by remote clients)";

    token = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Pre-shared token checked on `hello`, passed inline via the unit env.
        Convenient for tests/dev, but lands in the world-readable Nix store —
        prefer `tokenFile` in production. With neither `token` nor `tokenFile`
        set, a per-login random token is generated (the desktop default).
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the pre-shared token, loaded via systemd
        `LoadCredential` (never copied into the store). The file must be
        readable by this user's manager. Mutually exclusive with `token`.
      '';
    };

    idleTimeoutMs = lib.mkOption {
      type = lib.types.int;
      default = 1800000;
      description = ''
        Dispose a live-idle session's pi rpc child after this many ms with no
        attached clients. The committed session.jsonl persists, so the next
        attach resurrects it. 0 disables idle-GC.
      '';
    };

    maxLive = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = ''
        Ceiling on resident live pi rpc-child sessions; the least-recently-active
        idle session is evicted past it (resurrected on next attach). 0 = unlimited.
      '';
    };

    notifyCommand = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
      default = null;
      description = ''
        Executable run when a side-channel request parks with zero clients
        attached (design §6/§7), so the user is reached out-of-band. Receives
        SPACES_NOTIFY_SESSION_ID / _SESSION_NAME / _METHOD / _TITLE / _EXECUTOR.
        null disables it.
      '';
    };

    serveWebUi = lib.mkEnableOption (
      "serving the pi-web PWA client from this executor's WebSocket port "
      + "(same origin as the protocol)"
    );

    webUiPackage = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-web;
      defaultText = lib.literalExpression "inputs.self.packages.\${system}.pi-web";
      description = "The pi-web PWA assets served when `serveWebUi` is enabled.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Peer executor's stable id (matches its own `executorId`).";
            };
            host = lib.mkOption {
              type = lib.types.str;
              description = "Public hostname fronting the peer's WS (the PWA opens `wss://<host>/`).";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Every executor in this clan instance, surfaced verbatim to PWA clients
        via the unauthenticated `GET /executors` discovery endpoint. Include
        this executor too. Empty = clan-of-one fleet.
      '';
    };

    llmApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the API key for `llmUrl` (this executor's
        llama-swap), loaded via systemd `LoadCredential`. When set, the daemon
        sends it as a Bearer token on discovery and every completion — required
        when llama-swap is configured with `apiKeys`. null sends the historical
        `"dummy"` key, which a default-allow llama-swap ignores.
      '';
    };

    executorId = lib.mkOption {
      type = lib.types.str;
      default = "host";
      description = "Stable identifier for this executor, surfaced to clients (the `executor` half of `(executor, sessionId)`).";
    };

    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8012";
      description = "Base URL of the co-located OpenAI-compatible LLM endpoint (llama-swap), without the /v1 suffix.";
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Model a new session selects unless the client overrides it; must be served by `llmUrl`.";
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "pi provider a new session uses unless the client overrides it.";
    };

    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      description = "MemoryHigh for the daemon and for each per-session pi unit (SPACES_SESSIOND_MEMORY_HIGH).";
    };

    extensions = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ../pi-chat/extensions/bash-confirm.ts ];
      defaultText = lib.literalExpression "[ ../pi-chat/extensions/bash-confirm.ts ]";
      description = ''
        Extra pi extensions loaded into every pi rpc child via its settings.json.
        Defaults to bash-confirm, which gates `bash` behind the confirm
        side-channel.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Skill directories (SKILL.md trees) advertised to every session via
        settings.json, keyed by name. The pi-chat module forwards its merged
        skill set here when the loopback executor is enabled.
      '';
    };

    piSettings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = ''
        Extra keys merged into the daemon's generated settings.json.
        `defaultProvider`, `defaultModel`, `extensions`, `skills`, and
        `quietStartup` are populated by this module and win on conflict.
      '';
    };

    bashConfirm.allowPatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Regex patterns (ECMAScript) for `bash` commands that skip the
        bash-confirm prompt; staged as bash-confirm.json in the daemon's
        agent dir. Merges across modules.
      '';
    };

    sessionEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Extra environment variables --setenv'd into each per-session pi unit
        (skill plumbing: SKILL_CONFIG_SOCKET, …); the whole runtime — every
        tool/bash/extension in the session domain — inherits them. Values may
        use systemd specifiers `%h` / `%t` — they are expanded by systemd in
        the daemon unit's Environment= before the daemon reads them. Literal
        `%` characters are NOT escaped; avoid them.
      '';
    };

    allowedPaths = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = ''
                Host path granted to each per-session pi sandbox. May contain
                systemd specifiers `%h` / `%t`, expanded by systemd in the
                daemon unit's Environment=.
              '';
            };
            mode = lib.mkOption {
              type = lib.types.enum [
                "ro"
                "rw"
              ];
              default = "ro";
              description = "`ro` → read-only Landlock grant; `rw` → read-write.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Skill-plumbing paths granted into each per-session pi runtime's
        Landlock FS allowlist by access mode (the whole domain, inherited by
        every tool/bash/extension). NixOS modules that ship a skill publish
        their host paths here — same contract as the panel-era
        `services.pi-chat.sandboxAllowedPaths`, which forwards into this option.
      '';
    };

    openrouter.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Load the OpenRouter API key staged at
        /run/spaces-secrets/openrouter-api-key (see
        services.pi-chat.openrouter) into the daemon via LoadCredential.
      '';
    };

    openrouter.apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the OpenRouter API key, loaded via systemd
        `LoadCredential`. null (the default) falls back to the pi-chat-staged
        /run/spaces-secrets/openrouter-api-key (desktop). Set explicitly (e.g.
        a clan var) for a server executor.
      '';
    };

    memory.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the long-term memory (sediment) extension, sharing the
        vector store at ~/${memoryDbRel} with the legacy local spawn
        pattern.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(cfg.token != null && cfg.tokenFile != null);
        message = "services.pi-sessiond-local: set at most one of `token` or `tokenFile`.";
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    # Per-login token, shared between the daemon (LoadCredential) and the
    # panel (reads the file directly). RuntimeDirectoryPreserve keeps the
    # token across unit restarts; logout still wipes it with %t.
    systemd.user.services.pi-sessiond-local-token = lib.mkIf useGeneratedToken {
      description = "pi-sessiond-local token — per-login shared secret at %t/pi-sessiond-local/token";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "pi-sessiond-local";
        RuntimeDirectoryPreserve = "yes";
        ExecStart = tokenScript;
      };
    };

    systemd.user.services.pi-sessiond-local = {
      description = "pi-sessiond-local — per-user loopback pi executor (WebSocket transport + one Landlock-confined pi rpc child per session)";
      wantedBy = [ "default.target" ];
      requires = lib.optional useGeneratedToken "pi-sessiond-local-token.service";
      after = lib.optional useGeneratedToken "pi-sessiond-local-token.service";
      environment = {
        SPACES_SESSIOND_HOST = cfg.host;
        SPACES_SESSIOND_PORT = toString cfg.port;
        SPACES_SESSIOND_EXECUTOR_ID = cfg.executorId;
        SPACES_SESSIOND_DEFAULT_MODEL = cfg.defaultModel;
        SPACES_SESSIOND_DEFAULT_PROVIDER = cfg.defaultProvider;
        LLAMA_SWAP_BASE_URL = cfg.llmUrl;
        # The supervisor spawns each session's pi rpc child as a
        # `systemd-run --user` transient unit in the user manager; the
        # Landlock launcher confines it and bash runs inside that one
        # session domain (no per-command unit).
        SPACES_SESSIOND_SYSTEMD_RUN = "${systemdRunUser}";
        SPACES_SESSIOND_PI_SETTINGS = "${piSettings}";
        SPACES_SESSIOND_PI_BIN = piBin;
        # Every pi child is spawned through the Landlock launcher (design §6):
        # main.ts writes the per-session policy and execs the child through it.
        # The sole sandbox path for the desktop executor.
        SPACES_SESSIOND_LANDLOCK_EXEC = landlockExec;
        SPACES_SESSIOND_MEMORY_HIGH = cfg.memoryHigh;
        SPACES_SESSIOND_BASH_CONFIRM = "${bashConfirmJson}";
        # Skill plumbing for the per-session sandboxes. systemd expands the
        # %h/%t specifiers inside these JSON strings before the daemon
        # parses them, so sandbox.ts only ever sees absolute paths.
        SPACES_SESSIOND_SESSION_ENV = builtins.toJSON cfg.sessionEnv;
        SPACES_SESSIOND_ALLOWED_PATHS = builtins.toJSON (
          map (b: { inherit (b) source mode; }) cfg.allowedPaths
        );
        # PATH for the daemon AND (via main.ts --setenv forwarding) every
        # per-session sandbox is set through serviceConfig.Environment below —
        # NixOS pins environment.PATH for user units, so it can't be
        # overridden here.
        # NOT set: SPACES_SESSIOND_STATE_DIR —
        # main.ts falls back to $STATE_DIRECTORY from StateDirectory= below.
        #
        # Bun (and pi) want a writable HOME for caches; with ProtectHome=tmpfs
        # the real one is hidden, so point HOME at the state dir (specifiers
        # expand in Environment=).
        HOME = "%S/pi-sessiond-local";
        SPACES_SESSIOND_IDLE_TIMEOUT_MS = toString cfg.idleTimeoutMs;
        SPACES_SESSIOND_MAX_LIVE = toString cfg.maxLive;
        SPACES_SESSIOND_NOTIFY_CMD = lib.optionalString (cfg.notifyCommand != null) (
          toString cfg.notifyCommand
        );
        SPACES_SESSIOND_PWA_DIR = lib.optionalString cfg.serveWebUi (toString cfg.webUiPackage);
        # Fleet topology: read by main.ts loadPeers, exposed via GET /executors.
        SPACES_SESSIOND_PEERS_FILE = toString peersFile;
      }
      // lib.optionalAttrs cfg.memory.enable {
        # Memory extension (in-process): the LanceDB tree lives inside the
        # bound DB dir; the embedding-model cache is a /nix/store path —
        # visible through ProtectHome without a bind.
        SEDIMENT_DB = "%h/${memoryDbRel}/data";
        HF_HOME = toString sedimentPkg.modelCache;
      }
      // lib.optionalAttrs (cfg.token != null) {
        SPACES_SESSIOND_TOKEN = cfg.token;
      };
      serviceConfig = {
        ExecStart = lib.getExe' cfg.package "pi-sessiond";
        Restart = "on-failure";
        RestartSec = 2;
        # Skill CLIs (skill-config, notifications, signal, …) resolve by
        # bare name inside the bash sandboxes; main.ts forwards this PATH
        # via --setenv. The user manager's own PATH lacks the system
        # profile on NixOS, and environment.PATH is pinned by the NixOS
        # user-unit defaults, so override at the unit level — the same
        # line pi-chat.service uses for the panel. Last Environment= wins.
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
        # Per-session jsonl + the daemon-owned session index live here
        # (→ ~/.local/state/pi-sessiond-local for a user unit).
        StateDirectory = "pi-sessiond-local";
        # Token: desktop reads the per-login generated file; a server reads its
        # provisioned tokenFile. An inline `token` skips LoadCredential (it
        # rides the unit env instead).
        LoadCredential =
          lib.optional useGeneratedToken "token:%t/pi-sessiond-local/token"
          ++ lib.optional (cfg.tokenFile != null) "token:${toString cfg.tokenFile}"
          # OpenRouter key: an explicit apiKeyFile (e.g. a clan var) or the
          # pi-chat-staged desktop path (root:users 0640, readable via the user
          # manager). Lands in $CREDENTIALS_DIRECTORY/openrouter-api-key.
          ++ lib.optional cfg.openrouter.enable (
            "openrouter-api-key:"
            + (
              if cfg.openrouter.apiKeyFile != null then
                toString cfg.openrouter.apiKeyFile
              else
                "/run/spaces-secrets/openrouter-api-key"
            )
          )
          # llama-swap key (loadLlamaSwapKey): server executors authenticating
          # to a key-gated llama-swap. Desktop leaves it null.
          ++ lib.optional (cfg.llmApiKeyFile != null) "llama-swap-api-key:${toString cfg.llmApiKeyFile}";
        # Sandbox the daemon process: ProtectHome=tmpfs empties /home, /root
        # AND /run/user so the supervisor (and any in-process extension, e.g.
        # memory) cannot see $HOME. Bind back (a) the state dir (it lives under
        # /home), and (b) the user manager's IPC endpoints (%t/systemd private
        # socket + %t/bus), without which `systemd-run --user` — the
        # per-session unit spawner — cannot reach the manager ("Failed to
        # connect to user scope bus"). Everything else under /run/user (skill
        # sockets, other daemons) stays hidden from the daemon; each per-session
        # pi child gets its own Landlock domain, independent of the daemon's view.
        ProtectHome = "tmpfs";
        BindPaths = [
          "%S/pi-sessiond-local"
          "%t/systemd"
          "%t/bus"
        ]
        ++ lib.optional cfg.memory.enable "%h/${memoryDbRel}";
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        SystemCallArchitectures = "native";
        MemoryHigh = cfg.memoryHigh;
        # Deliberately NO RestrictNamespaces / PrivateUsers / ProtectProc:
        # the daemon must talk to the user manager to spawn each session's pi
        # rpc child as a transient unit (the Landlock launcher applies the
        # per-session sandbox there, not the supervisor).
      };
    };

    # The DB dir must exist before the daemon's BindPaths references it.
    # Same rule pi-chat ships; duplicates collapse.
    systemd.user.tmpfiles.rules = lib.mkIf cfg.memory.enable [
      "d %h/${memoryDbRel} 0750 - - -"
    ];
  };
}
