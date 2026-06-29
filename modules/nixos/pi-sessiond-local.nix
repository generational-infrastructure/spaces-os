# pi-sessiond-local — the desktop's per-user loopback executor.
#
# The same pi-sessiond binary as modules/nixos/pi-sessiond, but run as a
# systemd *user* service (it lives in the user's manager and dies at logout,
# like the per-session pi units the panel used to spawn). The daemon runs as
# the local user, hardened with ProtectHome=tmpfs so the supervisor (and any
# in-process extension) never sees $HOME; each per-session pi child is then
# spawned through the
# Landlock launcher (pi-landlock-exec), which applies a self-applied, deny-by-
# default Landlock domain (FS allowlist + egress port allowlist + IPC scoping)
# plus a seccomp denylist before exec'ing pi (docs/landlock-sandbox-design.md).
#
# Auth: a oneshot sibling unit generates a per-login token at
# $XDG_RUNTIME_DIR/pi-sessiond-local/token (0600); the daemon reads it via
# LoadCredential and the panel reads the same file directly — no secret ever
# touches the store.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pi-sessiond-local;

  sessiondLib = import ./pi-sessiond/lib.nix { inherit pkgs lib inputs; };
  inherit (sessiondLib) jsonFormat landlockExec;

  # Long-term memory (sediment) — same store the local spawn pattern used
  # (~/.local/state/spaces/pi/sediment), so memories persist across the
  # executor switch. The extension runs in-process, so the *daemon*
  # namespace gets the DB bind; the sandboxed pi children never see it.
  sedimentPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.sediment;
  memoryExtensionPkg = pkgs.callPackage ./pi-chat/extensions/memory { sediment = sedimentPkg; };
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
in
{
  options.services.pi-sessiond-local = {
    enable = lib.mkEnableOption (
      "pi-sessiond-local: a per-user loopback pi-sessiond user service — the "
      + "desktop's default executor (replaces the panel's local pi spawn)"
    );

    package = lib.mkOption {
      type = lib.types.package;
      default = import ../../packages/pi-sessiond { inherit pkgs inputs; };
      defaultText = lib.literalExpression "import ../../packages/pi-sessiond { inherit pkgs inputs; }";
      description = "The pi-sessiond daemon package (the WebSocket transport + session registry).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8768;
      description = "Loopback TCP port for the token-authenticated WebSocket listener.";
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
      default = [ ./pi-chat/extensions/bash-confirm.ts ];
      defaultText = lib.literalExpression "[ ./pi-chat/extensions/bash-confirm.ts ]";
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
    # Per-login token, shared between the daemon (LoadCredential) and the
    # panel (reads the file directly). RuntimeDirectoryPreserve keeps the
    # token across unit restarts; logout still wipes it with %t.
    systemd.user.services.pi-sessiond-local-token = {
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
      requires = [ "pi-sessiond-local-token.service" ];
      after = [ "pi-sessiond-local-token.service" ];
      environment = {
        SPACES_SESSIOND_HOST = "127.0.0.1";
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
      }
      // lib.optionalAttrs cfg.memory.enable {
        # Memory extension (in-process): the LanceDB tree lives inside the
        # bound DB dir; the embedding-model cache is a /nix/store path —
        # visible through ProtectHome without a bind.
        SEDIMENT_DB = "%h/${memoryDbRel}/data";
        HF_HOME = toString sedimentPkg.modelCache;
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
        LoadCredential = [
          "token:%t/pi-sessiond-local/token"
        ]
        # The OpenRouter key staged by the pi-chat module's system service
        # (root:users 0640) — readable through the user manager, lands in
        # $CREDENTIALS_DIRECTORY/openrouter-api-key for loadOpenRouterKey().
        ++ lib.optional cfg.openrouter.enable "openrouter-api-key:/run/spaces-secrets/openrouter-api-key";
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
