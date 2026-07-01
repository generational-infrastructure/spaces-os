# Pi-chat NixOS module.
#
# Standalone Quickshell chat panel for the spaces AI agent. Every chat
# session lives on a pi-sessiond executor reached over WebSocket — by
# default the per-user loopback daemon (services.pi-sessiond,
# enabled and fed its skill/sandbox surface by this module); remote
# executors come in via `executors`/`wsUrl`. The panel itself never
# spawns pi.
#
# The panel is a wlr-layer-shell surface anchored to the right edge,
# hidden by default, summoned via
#   quickshell ipc -c pi-chat call pi-chat toggle
# (wire to a compositor keybind for a global summon hotkey). Layer-
# shell means the panel never appears in alt-tab — that's the design
# point that ruled GNOME (no wlr-layer-shell) out of v1 scope.
#
# Files this module owns:
#   ~/.config/quickshell/pi-chat/              (materialized shell config, fresh mtimes for Qt qmlcache)
#   ~/.local/state/spaces/pi/                  (panel index: sessions.json, activity.json; skills-defs,
#                                               skill-config store, notifications dir for the bash sandboxes)
#   /run/spaces-secrets/openrouter-api-key     (when openrouter.enable = true; root:users 0640)
#
# User systemd units:
#   pi-chat.service                            (materializes shell config, then runs `quickshell -c pi-chat`)
#   spaces-skill-config-daemon.service         (skill-config IPC, $XDG_RUNTIME_DIR/spaces-skill-config.sock)
#   spaces-notify-forward.service              (D-Bus notifications -> pi-chat shell IPC)
#   spaces-location-update.service + timer     (geoclue -> $XDG_RUNTIME_DIR/spaces/location.json)
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pi-chat;

  jsonFormat = pkgs.formats.json { };

  skillsDir = ../../../skills;

  skillConfigPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config;
  skillConfigDaemonPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config-daemon;
  notificationsCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.notifications-cli;
  googleCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.google-cli;
  osmCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.osm-cli;
  wikipediaCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.wikipedia-cli;
  caldavCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.caldav-cli;
  wikidataCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.wikidata-cli;
  contactsCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.contacts-cli;
  mailCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.mail-cli;
  sedimentPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.sediment;
  desktopEntriesPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-chat-desktop-entries;

  # Memory extension: nix derivation that substitutes the absolute
  # sediment binary path into a single-file pi extension. Path-typed
  # so the existing extensions-loading logic treats it like any other
  # bundled extension.
  memoryExtensionPkg = pkgs.callPackage ./extensions/memory { sediment = sedimentPkg; };

  shellDir = ../../../programs/pi-chat;
  shellName = "pi-chat";

  # Executors the panel attaches to, with wsUrl/wsToken/wsTokenFile folded in as
  # the single-executor "remote" shorthand. A token is either inline (`token`)
  # or read from a file (`tokenFile`); the file is staged under
  # /run/spaces-secrets (root:users 0640) and read by the panel at connect time,
  # so the secret never lands in the world-readable config or the Nix store.
  wsExecutors =
    cfg.executors
    ++ lib.optional (cfg.wsUrl != "") {
      id = "remote";
      url = cfg.wsUrl;
      token = cfg.wsToken;
      tokenFile = cfg.wsTokenFile;
    };
  tokenSecretPath = id: "/run/spaces-secrets/pi-chat-token-${id}";
  fileTokenExecutors = lib.filter (e: e.tokenFile != null) wsExecutors;
  # Config view: a file-backed executor advertises a `tokenPath` (read at
  # runtime) and carries no inline token; inline-token executors pass through.
  configExecutors = map (
    e:
    {
      inherit (e) id url;
      token = if e.tokenFile != null then "" else e.token;
    }
    // lib.optionalAttrs (e.tokenFile != null) { tokenPath = tokenSecretPath e.id; }
  ) wsExecutors;

  # Materialize the chat shell into ~/.config/quickshell/pi-chat with
  # fresh mtimes (Qt qmlcache invalidation — see pi-chat.service).
  materializeShell = pkgs.writeShellScript "pi-chat-materialize" ''
    set -eu
    src=${shellDir}
    dst="$HOME/.config/quickshell/${shellName}"
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    # cp without -p leaves mtimes at the current time.
    cp -rT "$src" "$dst"
    chmod -R u+w "$dst"
  '';

  # State paths use systemd tmpfiles' %h/%t substitutions when written
  # via systemd.user.tmpfiles. For module-internal use we keep the
  # literal expansions that tmpfiles understands.
  stateRel = ".local/state/spaces/pi";
  workspacesRel = ".local/share/spaces/workspaces";
  sessionsIndexRel = "${stateRel}/sessions.json";
  skillsDefsRel = "${stateRel}/skills-defs";
  skillConfigStoreRel = "${stateRel}/skill-config";
  # Notification history landing zone for the notifications skill.
  # The pi sandbox bind-mounts this dir read-only. When noctalia is
  # also running on the system, its `NOCTALIA_NOTIF_HISTORY_FILE`
  # environment can be pointed here for continuity — but the pi-chat
  # module no longer manages that redirect; operators wanting it set
  # systemd.user.services.noctalia-shell.environment themselves.
  notificationsRel = "${stateRel}/notifications";
  # Long-term memory store (sediment). The vector DB is shared across
  # all sessions of the same user; the per-session sandbox bind-mounts
  # it read-write. The embedding model lives in a /nix/store path
  # baked at build time (sedimentPkg.modelCache) so first runs need
  # no network.
  memoryDbRel = "${stateRel}/sediment";

  # All skills (built-ins + user-supplied via cfg.skills), merged
  # into one linked-farm so the plugin can pass a single dir or pi
  # can read each one by absolute path from settings.json.
  #
  # The signal skill follows services.spaces-signal.enable (which in
  # turn defaults to services.pi-chat.enable). When opted out, the
  # SKILL.md does not reach the agent — it advertises a CLI the
  # sandbox can't actually reach, so dropping it avoids confusing
  # tool calls.
  builtinSkills = {
    datetime = "${skillsDir}/datetime";
    location = "${skillsDir}/location";
    maps = "${skillsDir}/maps";
    wikipedia = "${skillsDir}/wikipedia";
    notifications = "${skillsDir}/notifications";
    skill-config = "${skillsDir}/skill-config";
    calendar = "${skillsDir}/calendar";
    contacts = "${skillsDir}/contacts";
    email = "${skillsDir}/email";
    google = "${skillsDir}/google";
    wikidata = "${skillsDir}/wikidata";
  }
  // lib.optionalAttrs (config.services.spaces-signal.enable or false) {
    signal = "${skillsDir}/signal";
  };
  allSkills = builtinSkills // cfg.skills;

  # Pi extensions: bool means "use the bundled .ts shipped here"; path
  # means use that file/dir verbatim.
  bundledExtensions = {
    bash-confirm = ./extensions/bash-confirm.ts;
    llama-swap-discover = ./extensions/llama-swap-discover.ts;
    memory = memoryExtensionPkg;
  };
  resolveExtension =
    name: value:
    if builtins.isBool value then
      (
        if value then
          bundledExtensions.${name}
            or (throw "services.pi-chat.extensions.${name}: no bundled extension by that name")
        else
          null
      )
    else
      value;
  # All bundled extensions are on by default; cfg.extensions can
  # override either to a different path or to `false` to disable.
  enabledExtensions = lib.filterAttrs (_name: value: if builtins.isBool value then value else true) (
    bundledExtensions // cfg.extensions
  );
  resolvedEnabledExtensions = lib.mapAttrs resolveExtension enabledExtensions;

  # D-Bus notification forwarder. Posts incoming notifications into
  # the active chat session via the standalone shell's IPC. The
  # `send` verb on the `pi-chat` IPC target is unchanged across the
  # plugin → standalone cutover; only the way we reach it differs:
  # noctalia plugin used `noctalia-shell ipc call plugin:pi-chat send`,
  # standalone uses `quickshell ipc -c pi-chat call pi-chat send`.
  notifScript = pkgs.writeShellScript "spaces-notify-forward" ''
    set -u
    export PATH="${
      lib.makeBinPath [
        pkgs.dbus
        pkgs.coreutils
        pkgs.gnused
        pkgs.quickshell
      ]
    }:$PATH"

    # Colon-separated list of app names to ignore (case-insensitive).
    IGNORED="${lib.concatStringsSep ":" (map lib.toLower cfg.notificationForwarding.ignoredApps)}"

    is_ignored() {
      local app IFS=':'
      app=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
      for i in $IGNORED; do
        [ "$app" = "$i" ] && return 0
      done
      return 1
    }

    # `stdbuf -oL` forces line buffering on dbus-monitor's stdout;
    # otherwise it switches to block buffering when piped and the
    # `while read` loop only fires after several KB of accumulated
    # output — i.e. never, under normal notification volume.
    stdbuf -oL dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'" |
    while IFS= read -r line; do
      case "$line" in
        *member=Notify*) n=0; app=""; summary=""; body="" ;;
        *'string "'*)
          n=$((n + 1))
          val="''${line#*string \"}"
          val="''${val%\"}"
          case $n in
            1) app="$val" ;;
            3) summary="$val" ;;
            4) body="$val"
               if ! is_ignored "$app"; then
                 text="[Notification] ''${app}: ''${summary}"
                 [ -n "$body" ] && text="''${text} — ''${body}"
                 quickshell ipc -c ${shellName} call ${shellName} send "$text" || true
               fi
               ;;
          esac
          ;;
      esac
    done
  '';

  locationScript = pkgs.writeShellScript "spaces-location-update" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.geoclue2
        pkgs.jq
        pkgs.coreutils
        pkgs.gnused
      ]
    }:$PATH"
    where_am_i="${pkgs.geoclue2}/libexec/geoclue-2.0/demos/where-am-i"

    out_dir="''${XDG_RUNTIME_DIR}/spaces"
    mkdir -p "$out_dir"
    out="$out_dir/location.json"

    raw=$("$where_am_i" -t 30 -a 8 2>&1) || {
      echo "where-am-i failed" >&2
      exit 1
    }

    # Output format (locale-dependent decimal comma):
    #   Latitude:    30,038300°
    #   Longitude:   31,210200°
    #   Accuracy:    25000,000000 meters
    #   Description: ipf fallback (from WiFi data)
    # Take the last block in case multiple updates are reported.
    lat=$(echo "$raw" | sed -n 's/.*Latitude: *\([0-9,.-]*\).*/\1/p' | tail -1 | tr ',' '.')
    lon=$(echo "$raw" | sed -n 's/.*Longitude: *\([0-9,.-]*\).*/\1/p' | tail -1 | tr ',' '.')
    acc=$(echo "$raw" | sed -n 's/.*Accuracy: *\([0-9,.-]*\).*/\1/p' | tail -1 | tr ',' '.')
    desc=$(echo "$raw" | sed -n 's/.*Description: *//p' | tail -1)
    ts=$(date --iso-8601=seconds)

    jq -n \
      --arg lat "$lat" \
      --arg lon "$lon" \
      --arg acc "$acc" \
      --arg desc "$desc" \
      --arg ts "$ts" \
      '{latitude: ($lat|tonumber), longitude: ($lon|tonumber), accuracy_meters: ($acc|tonumber), description: $desc, updated: $ts}' \
      > "''${out}.tmp" && mv "''${out}.tmp" "$out"
  '';
in
{
  # pi-chat needs a local LLM endpoint; our llama-swap wrapper
  # configures the upstream `services.llama-swap` with port 8012
  # (matching this module's default `llmUrl`), a vetted model set,
  # GPU-accelerated llama-cpp, and the suspend/resume hooks. Users
  # who want a different endpoint set `services.llama-swap.enable
  # = false` and `services.pi-chat.llmUrl = "…"` to point elsewhere.
  imports = [
    ../llama-swap.nix
    inputs.self.nixosModules.signal-cli
    # Voice-to-text (Mod+S). Imported here so every pi-chat consumer
    # gets it for free; voxtype's config is unconditional, so it is
    # enabled by the mere import.
    inputs.self.nixosModules.voxtype
    # The per-user loopback executor the panel attaches to by default
    # (services.pi-chat.localExecutor enables + port-syncs it). Keyed so a
    # dual-role clan machine (this client + the executor role, which imports
    # the same module) collapses the two imports into one.
    (inputs.self.nixosModules.pi-sessiond // { key = "spaces/nixosModules/pi-sessiond"; })
    # Agent integrations: broker + Landlock-confined MCP units. Imported here so
    # every pi-chat consumer gets the feature; enabled by default below.
    inputs.self.nixosModules.spaces-integrations
  ];

  options.services.pi-chat = {
    enable = lib.mkEnableOption "pi-chat: standalone Quickshell chat panel for the spaces AI agent (pi --mode rpc)";

    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8012";
      description = "Base URL of an OpenAI-compatible LLM server (without /v1 suffix).";
    };

    wsUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        WebSocket URL of a pi-sessiond executor (e.g. ws://server:8770).
        When set, the panel attaches sessions over this connection instead
        of spawning pi locally; empty keeps the local executor.
      '';
    };

    wsToken = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Pre-shared `hello` token for the executor in `wsUrl`. Written into
        the world-readable panel config — use only where that is acceptable
        (tests / trusted LAN); a tokenFile indirection is a later refinement.
      '';
    };

    wsTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Host path to a file holding the `hello` token for the executor in
        `wsUrl`. Staged into /run/spaces-secrets (root:users 0640) and read by
        the panel at connect time, so the token never lands in the
        world-readable config or the Nix store. Mutually exclusive with
        `wsToken`. Pass a runtime path (e.g. a sops-nix secret), not a store path.
      '';
    };

    executors = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Stable executor id; shown per session and used as create_session's target.";
            };
            url = lib.mkOption {
              type = lib.types.str;
              description = "pi-sessiond WebSocket URL (e.g. ws://server:8770).";
            };
            token = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Pre-shared `hello` token for this executor.";
            };
            tokenFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = ''
                Host path to a file holding this executor's `hello` token. Staged
                into /run/spaces-secrets and read by the panel at connect time
                (kept out of the world-readable config and the Nix store).
                Mutually exclusive with `token`.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        Remote pi-sessiond executors the panel attaches to simultaneously; each
        chat session is pinned to one by its `id` (multi-homing, design stage 4).
        `wsUrl`/`wsToken` are a deprecated shorthand for a single
        `{ id = "remote"; ... }` entry.
      '';
    };

    defaultExecutor = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Executor id new (and legacy, un-pinned) sessions are created on.
        Empty falls back to the first configured executor. (Local execution
        is itself an executor — the loopback pi-sessiond; there is no
        in-process spawn.)
      '';
    };

    localExecutor = {
      enable =
        lib.mkEnableOption "the per-user loopback pi-sessiond (pi-sessiond) as the panel's executor"
        // {
          default = true;
        };
      id = lib.mkOption {
        type = lib.types.str;
        default = "host";
        description = "Executor id the loopback daemon is advertised under.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8768;
        description = "Loopback port pi-sessiond listens on (the panel connects to ws://127.0.0.1:<port>).";
      };
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "gemma4:e4b";
      description = ''
        Model pi selects at session start. Must be served by the
        OpenAI-compatible endpoint at `llmUrl` (i.e. configured in
        `services.llama-swap.settings.models`). The full model list
        shown in the model picker is discovered at runtime from
        `''${llmUrl}/v1/models` by the executor daemon.
      '';
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = ''
        Provider pi selects at session start. The local default is
        "local" — populated by the executor daemon's /v1/models
        discovery. Set to "openrouter" (or any other bundled pi
        provider) to route chat through that backend.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Additional skill directories for pi, keyed by name. Merged
        with the built-in spaces skills (datetime, location, maps,
        skill-config, calendar, google, notifications).
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.bool lib.types.path);
      default = { };
      description = ''
        Pi extensions to enable, keyed by name. Each value can be:
          - `true` to enable a bundled extension (`bash-confirm`,
            `llama-swap-discover`)
          - `false` to explicitly disable a bundled extension
          - A path to a .ts file or directory containing an index.ts
        Bundled extensions default to enabled.
      '';
    };

    sandboxAllowedPaths = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = ''
                Host path granted to each per-session pi sandbox. May
                contain systemd specifiers `%h` (user `$HOME`) and `%t`
                (`$XDG_RUNTIME_DIR`); both are expanded by systemd in the
                daemon unit's Environment=.
              '';
            };
            mode = lib.mkOption {
              type = lib.types.enum [
                "ro"
                "rw"
              ];
              default = "ro";
              description = ''
                `ro` → read-only Landlock grant; `rw` → read-write.
                Default `ro` because skills almost always only need to
                read configuration and data they did not produce.
              '';
            };
          };
        }
      );
      default = [ ];
      example = lib.literalExpression ''
        [
          # The signal skill (see modules/nixos/signal-cli.nix): message
          # store + attachments read-only, and the bridge's sandbox
          # runtime dir read-write (enqueue.sock appears inside it). The
          # signal-cli daemon socket and panel.sock are deliberately NOT
          # exposed — that split is the send-approval gate's boundary.
          { source = "%h/.local/state/spaces/signal"; mode = "ro"; }
          { source = "%h/.local/share/signal-cli/attachments"; mode = "ro"; }
          { source = "%t/spaces-signal/sandbox"; mode = "rw"; }
        ]
      '';
      description = ''
        Extra filesystem grants for the per-session pi sandboxes of the
        loopback executor (pi-sessiond).

        NixOS modules that add a skill **MUST** publish their required
        host paths through this option. Forwarded into
        `services.pi-sessiond.allowedPaths` after the pi-chat-owned
        baseline binds; the daemon folds them into each session's Landlock
        FS allowlist.
      '';
    };

    sandboxEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        { SPACES_SIGNAL_DB = "%h/.local/state/spaces/signal/messages.db"; }
      '';
      description = ''
        Extra environment variables for the per-session pi sandboxes of the
        loopback executor (pi-sessiond).

        NixOS modules that add a skill **MUST** publish here any absolute
        path a skill CLI must resolve independently of the sandbox's
        remapped `$HOME`: each session runs under a private per-session
        agent dir as `$HOME`, so a `~`-relative default no longer points at
        a host path granted via `sandboxAllowedPaths`. May contain systemd
        specifiers `%h` / `%t`, expanded in the daemon unit's Environment=.
        Forwarded into `services.pi-sessiond.sessionEnv` after the
        pi-chat-owned baseline — same contract as `sandboxAllowedPaths`.
      '';
    };

    bashConfirm = {
      allowPatterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Regex patterns (ECMAScript) for `bash` commands that skip the
          confirm prompt. Merges across modules — skill modules append
          their own patterns here instead of asking users to edit the
          list.

          Unanchored unless you write `^` / `$` yourself.
        '';
      };
    };

    piSettings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = ''
        Extra keys to merge into the loopback executor's generated
        settings.json (forwarded to services.pi-sessiond.piSettings).
        `defaultProvider`, `defaultModel`, `extensions`, and `skills` are
        populated by the modules and cannot be overridden here.
      '';
    };

    openrouter = {
      enable = lib.mkEnableOption "OpenRouter provider for pi";
      apiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Host path to a file containing the OpenRouter API key (single
          line). Loaded into /run/spaces-secrets/openrouter-api-key by
          a root-only system service, then bound into each pi-chat
          scope via systemd-run's LoadCredential= so the key never
          touches user-readable storage.
        '';
      };
    };

    notificationForwarding = {
      enable = lib.mkEnableOption "forward D-Bus notifications into the chat panel";
      ignoredApps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "pi-chat"
          "spaces-chat"
        ];
        description = "App names whose notifications are not forwarded (exact match, case-insensitive).";
      };
    };

    locationUpdates = {
      enable = lib.mkEnableOption "periodic GeoClue location updates" // {
        default = true;
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "10min";
        description = "OnUnitActiveSec= for the location-update timer.";
      };
    };
    sandbox = {
      memoryHigh = lib.mkOption {
        type = lib.types.str;
        default = "4G";
        description = "MemoryHigh= applied to every per-session scope.";
      };
      idleTimeoutMinutes = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = ''
          Minutes the plugin waits after a session goes idle before
          stopping its scope. Used by the QML side; surfaced here so
          ops can change defaults centrally.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Agent integrations ride with the panel: the broker + Landlock-confined MCP
    # units come up (inert until an integration is declared, or added at runtime
    # via Settings -> Integrations). Overridable per-host.
    services.spaces-integrations.enable = lib.mkDefault true;

    assertions = [
      {
        assertion = !cfg.openrouter.enable || cfg.openrouter.apiKeyFile != null;
        message = "services.pi-chat.openrouter.apiKeyFile must be set when openrouter.enable = true.";
      }
      {
        assertion = !(cfg.wsToken != "" && cfg.wsTokenFile != null);
        message = "services.pi-chat: set at most one of `wsToken` or `wsTokenFile`.";
      }
    ]
    ++ map (e: {
      assertion = !(e.token != "" && e.tokenFile != null);
      message = ''services.pi-chat.executors."${e.id}": set at most one of `token` or `tokenFile`.'';
    }) wsExecutors;

    # Baseline bash-confirm allow-list. Set in the config block (not
    # via the option's `default`) so other modules' contributions
    # concatenate instead of replacing.
    services.pi-chat.bashConfirm.allowPatterns = [
      # skill-config: proxied through an IPC daemon, no attacker-
      # controlled payloads.
      "^skill-config(\\s|$)"
      # notifications: thin reader over a host-managed history file.
      "^notifications(\\s|$)"
      # wikidata: read-only public Wikidata queries, no auth, no mutation.
      "^wikidata-cli(\\s|$)"
      # wikipedia: read-only public Wikipedia/MediaWiki queries, no auth, no mutation.
      "^wikipedia-cli(\\s|$)"
      # google: Gmail + Calendar via the google-cli wrapper. Whitelisted
      # in full (read AND mutate) at the user's request — sends mail and
      # adds/deletes events without a per-command confirm prompt.
      "^google-cli(\\s|$)"
    ];

    # The loopback executor becomes the default target for new sessions.
    # mkDefault keeps it overridable to another configured executor id.
    # (There is no local in-process spawn anymore: a session pinned to ""
    # has no transport — the panel falls back to the first configured
    # executor instead.)
    services.pi-chat.defaultExecutor = lib.mkIf cfg.localExecutor.enable (
      lib.mkDefault cfg.localExecutor.id
    );

    # The loopback daemon the panel attaches to. Imported above; enabled,
    # port-synced, and fed the panel-side skill/sandbox surface so one flag
    # drives both halves.
    services.pi-sessiond = lib.mkIf cfg.localExecutor.enable {
      enable = lib.mkDefault true;
      port = lib.mkDefault cfg.localExecutor.port;
      llmUrl = lib.mkDefault cfg.llmUrl;
      defaultModel = lib.mkDefault cfg.defaultModel;
      defaultProvider = lib.mkDefault cfg.defaultProvider;
      memoryHigh = lib.mkDefault cfg.sandbox.memoryHigh;
      skills = allSkills;
      inherit (cfg) piSettings;
      bashConfirm.allowPatterns = cfg.bashConfirm.allowPatterns;
      openrouter.enable = cfg.openrouter.enable;
      # The memory extension is keyed by the daemon's own memory.enable
      # (which also binds the sediment DB into the daemon namespace), and
      # llama-swap-discover stays out — the daemon runs its own /v1/models
      # discovery and a second registration would double-list the local
      # provider. Everything else forwards as resolved paths.
      extensions = lib.attrValues (
        lib.filterAttrs (
          name: _: name != "memory" && name != "llama-swap-discover"
        ) resolvedEnabledExtensions
      );
      memory.enable = enabledExtensions ? memory;
      # Skill plumbing for the per-session sandboxes — same env + binds the
      # panel used to assemble per session, now applied daemon-side.
      # %h/%t expand in the daemon unit's Environment=.
      sessionEnv = {
        SKILL_CONFIG_SOCKET = "%t/spaces-skill-config.sock";
        SPACES_OPEN_URL_SOCKET = "%t/spaces-pi-open-url.sock";
        SPACES_PI_CHAT_STATE_DIR = "%h/${stateRel}";
        SPACES_NOTIFICATIONS_FILE = "%h/${notificationsRel}/history.json";
      }
      // cfg.sandboxEnv;
      allowedPaths = [
        # A missing socket is fine: pi-landlock-exec skips an absent grant
        # non-fatally, and the CLIs degrade gracefully when the skill-config
        # daemon / panel listener is down.
        {
          source = "%t/spaces-skill-config.sock";
          mode = "rw";
        }
        {
          source = "%t/spaces-pi-open-url.sock";
          mode = "rw";
        }
        # skill-config needs the skill schemas (read-only nix-store
        # symlinks) and the user's config/secrets store (read-write).
        { source = "%h/${skillsDefsRel}"; }
        {
          source = "%h/${skillConfigStoreRel}";
          mode = "rw";
        }
        { source = "%h/${notificationsRel}"; }
      ]
      ++ cfg.sandboxAllowedPaths;
    };

    # llama-swap supplies the default LLM endpoint; enable by default
    # so a fresh install boots into a usable state.
    services.llama-swap.enable = lib.mkDefault true;

    # Every built-in skill's CLI lands on the system PATH. Two reasons:
    #   1. pi-sessiond forwards a PATH containing the system
    #      profile into every per-session sandbox, so the agent can shell
    #      out by bare name (`signal threads`, `osm-cli search …`,
    #      `caldav list …`, etc.) without each skill's SKILL.md having
    #      to spell out absolute store paths.
    #   2. The user can run the exact same commands from a normal
    #      terminal — debug a skill's behaviour, script around it,
    #      or just use it without going through the chat panel.
    # `sediment` is on PATH for the same reason: the operator can
    # poke the same DB the chat sandbox writes to with `sediment
    # stats`, `sediment list`, `sediment recall "<q>"`, etc.
    # SEDIMENT_DB below points at the per-user DB so no `--db` flag
    # is needed.
    environment.systemPackages = [
      skillConfigPkg
      notificationsCliPkg
      googleCliPkg
      osmCliPkg
      wikipediaCliPkg
      caldavCliPkg
      wikidataCliPkg
      contactsCliPkg
      mailCliPkg
      sedimentPkg
      # Quickshell ships the `quickshell` binary used by the user
      # service AND the `quickshell ipc` CLI used by the toggle
      # helper, the notification forwarder, and the test harnesses.
      pkgs.quickshell
      # `notify-send` so users + the agent can post desktop
      # notifications. spaces-notify-forward then bridges those
      # straight back into the chat panel via the IPC `send` verb.
      pkgs.libnotify
      # Low-level IPC helper for the chat panel: `pi-chat-toggle [verb]`
      # forwards `verb` (default `toggle`) to the shell's IPC. The
      # notifying shortcut wrappers (spaces-chat-toggle /
      # spaces-chat-quick-launch in modules/nixos/spaces-commands.nix)
      # call this; kept on PATH so it is also usable directly.
      (pkgs.writeShellScriptBin "pi-chat-toggle" ''
        exec ${pkgs.quickshell}/bin/quickshell ipc -c ${shellName} call ${shellName} "''${1:-toggle}"
      '')
      desktopEntriesPkg
    ];

    environment.sessionVariables = {
      # sediment stashes its access.db alongside (i.e. in the parent
      # of) SEDIMENT_DB. The sandbox only bind-mounts the leaf
      # `memoryDbRel` dir RW, so SEDIMENT_DB has to point at a
      # subdirectory of it — that way both the LanceDB tree and the
      # access.db sibling land inside the bind mount.
      SEDIMENT_DB = "$HOME/${memoryDbRel}/data";
    };

    # Panel-side state skeleton plus the skill plumbing dirs the per-session
    # sandboxes use (skills-defs / skill-config store / notifications).
    systemd.user.tmpfiles.rules = [
      "d %h/.local 0755 - - -"
      "d %h/.local/state 0755 - - -"
      "d %h/.local/state/spaces 0755 - - -"
      "d %h/${stateRel} 0755 - - -"
      "d %h/.local/share 0755 - - -"
      "d %h/.local/share/spaces 0755 - - -"
      "d %h/${workspacesRel} 0755 - - -"
      # An empty sessions.json so the plugin can read it on first
      # launch without a special-case branch.
      ''f %h/${sessionsIndexRel} 0644 - - - {"version":1,"sessions":[],"activeSessionId":null}''
      # skill-config CLI resolves schemas from $state_dir/skills-defs/<skill>/SKILL.md.
      # Symlink each skill so request-input can validate fields before
      # contacting the daemon.
      "d %h/${skillsDefsRel} 0755 - - -"
      # The notification helper script forwards desktop notifications
      # into the chat panel. Notifications never enter the pi sandbox
      # via this dir — the helper just calls `quickshell ipc … send`.
      # Kept as a tmpfile because the notifications skill still reads
      # `$NOCTALIA_NOTIF_HISTORY_FILE` when present (for ops that opt
      # back into noctalia and want continuity); the directory must
      # exist so the redirect doesn't ENOENT.
      "d %h/${notificationsRel} 0755 - - -"
    ]
    ++ lib.mapAttrsToList (name: path: "L+ %h/${skillsDefsRel}/${name} - - - - ${path}") allSkills
    ++ [
      # skill-config stores per-skill config.toml / secrets.toml here.
      "d %h/${skillConfigStoreRel} 0755 - - -"
    ]
    ++ [
      # sediment DB only — the embedding-model cache is a /nix/store
      # path baked into the sediment package, not a writable dir.
      "d %h/${memoryDbRel} 0750 - - -"
    ]
    ++ [
      "d %h/.config 0755 - - -"
      "d %h/.config/quickshell 0755 - - -"
    ];

    # ── User services ────────────────────────────────────────────────

    # The standalone chat panel. Layer-shell surface anchored to the
    # right edge, hidden by default, summoned via
    #   quickshell ipc -c ${shellName} call ${shellName} toggle
    # (wire a compositor keybind for global summon). Long-running
    # service — the IpcHandler only answers while quickshell is up.
    #
    # ExecStartPre materializes the QML with fresh mtimes: Qt's qmlcache
    # keys bytecode by (absolute path, source mtime), and every
    # /nix/store file has mtime 1970, so a store symlink would let Qt
    # keep stale bytecode across rebuilds. Copying on every (re)start
    # invalidates the cache, so a plain `systemctl --user restart
    # pi-chat.service` always picks up the latest build — that's the
    # Mod+Shift+A reload, and the autostart fallback below routes
    # through here too.
    systemd.user.services.pi-chat = {
      description = "pi-chat Quickshell panel";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      restartTriggers = [ shellDir ];
      # QtWebSockets lives outside quickshell's bundled QML path; quickshell's
      # wrapper --prefixes its own paths onto NIXPKGS_QT6_QML_IMPORT_PATH, so
      # this composes rather than clobbering.
      environment.NIXPKGS_QT6_QML_IMPORT_PATH = "${pkgs.qt6.qtwebsockets}/lib/qt-6/qml";
      serviceConfig = {
        ExecStartPre = "${materializeShell}";
        ExecStart = "${pkgs.quickshell}/bin/quickshell -c ${shellName}";
        Restart = "on-failure";
        RestartSec = 3;
        Slice = "session.slice";
        # Quickshell shells out to helpers (notify-send, dbus-send,
        # the pi binary) by bare name; give them the standard PATH.
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };

    # Skill-config IPC daemon. Lives as a regular user systemd unit;
    # each pi-chat scope bind-mounts its socket at /run/spaces/skill-config.sock.
    systemd.user.services.spaces-skill-config-daemon = {
      description = "skill-config IPC daemon (pi-chat)";
      after = [ "default.target" ];
      wantedBy = [ "default.target" ];
      environment = {
        # Default socket lives in $XDG_RUNTIME_DIR so it's torn down
        # when the user session ends.
        SKILL_CONFIG_SOCKET = "%t/spaces-skill-config.sock";
      };
      serviceConfig = {
        ExecStart = lib.getExe skillConfigDaemonPkg;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.user.services.spaces-notify-forward = lib.mkIf cfg.notificationForwarding.enable {
      description = "Forward desktop notifications to the pi-chat panel";
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = notifScript;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.user.services.spaces-location-update = lib.mkIf cfg.locationUpdates.enable {
      description = "Update pi-chat location via GeoClue";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = locationScript;
      };
    };
    systemd.user.timers.spaces-location-update = lib.mkIf cfg.locationUpdates.enable {
      description = "Periodically update pi-chat location";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "30s";
        OnUnitActiveSec = cfg.locationUpdates.interval;
      };
    };

    # ── System services ──────────────────────────────────────────────

    # Make the openrouter API key reachable from the user manager
    # without putting it in any user-readable file or store path. A
    # tmpfiles entry can't do this — the file content lives on the
    # host. We stage it under /run, owned root:users, mode 0640 so a
    # group-matched user can read it but other users can't.
    #
    # systemd-run --user --scope --property=LoadCredential=foo:/run/...
    # then copies it into $CREDENTIALS_DIRECTORY for the pi process,
    # which `!cat $CREDENTIALS_DIRECTORY/openrouter-api-key` resolves
    # at request time. Pi reads the credential at request time.
    systemd.services.spaces-secrets-load =
      lib.mkIf (cfg.openrouter.enable || fileTokenExecutors != [ ])
        {
          description = "Stage pi-chat secrets for the user manager";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0027";
          };
          script = ''
            set -eu
            install -d -m 0750 -o root -g users /run/spaces-secrets
          ''
          + lib.optionalString cfg.openrouter.enable ''
            install -m 0640 -o root -g users \
              ${cfg.openrouter.apiKeyFile} \
              /run/spaces-secrets/openrouter-api-key
          ''
          + lib.concatMapStrings (e: ''
            install -m 0640 -o root -g users \
              ${e.tokenFile} \
              ${tokenSecretPath e.id}
          '') fileTokenExecutors;
        };

    # Shell config file. The QML side reads this on startup so we
    # don't have to thread a dozen env vars through the user manager.
    # Symlink from a generation-pinned store path.
    environment.etc."spaces/pi-chat.json".source = jsonFormat.generate "pi-chat-shell.json" (
      {
        inherit (cfg) llmUrl;
        inherit (cfg) wsUrl;
        inherit (cfg) wsToken;
        executors = configExecutors;
        inherit (cfg) defaultExecutor;
        inherit (cfg) defaultModel;
        inherit (cfg) defaultProvider;
        inherit (cfg.sandbox) idleTimeoutMinutes;
        # memoryDbDir is $HOME-relative — the user-writable sediment
        # vector store. The panel only needs it for the destructive
        # "wipe memory" action; recall/storage runs inside
        # pi-sessiond.
        memoryDbDir = memoryDbRel;
        # memoryHfHome is the absolute /nix/store path with the pre-baked
        # embedding-model cache. Not read by the panel — kept for ops
        # tooling (e.g. the VM memory e2e runs the sediment CLI under
        # sudo, which strips environment.sessionVariables).
        memoryHfHome = toString sedimentPkg.modelCache;
      }
      // lib.optionalAttrs cfg.localExecutor.enable {
        # Per-user loopback pi-sessiond (pi-sessiond). The panel folds
        # this into its executors list with the per-login token path
        # $XDG_RUNTIME_DIR/pi-sessiond/token — the secret itself never
        # lands in this world-readable file.
        localExecutor = {
          inherit (cfg.localExecutor) id;
          url = "ws://127.0.0.1:${toString cfg.localExecutor.port}";
        };
      }
    );

    # XDG autostart entry, for compositors that don't follow the
    # systemd-managed graphical-session path (e.g. user runs niri via
    # an exec wrapper instead of niri-session). It starts the systemd
    # unit rather than launching quickshell directly, so the panel still
    # goes through pi-chat.service's materialize ExecStartPre. The unit
    # is the canonical vector; this is a belt-and-braces fallback.
    environment.etc."xdg/autostart/pi-chat.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=pi-chat
      Comment=Standalone Quickshell chat panel for the spaces AI agent
      Icon=pi-chat
      Exec=${pkgs.systemd}/bin/systemctl --user start pi-chat.service
      X-GNOME-Autostart-enabled=true
      OnlyShowIn=niri;sway;Hyprland;river;KDE;
    '';
  };
}
