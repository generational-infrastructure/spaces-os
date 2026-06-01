# Pi-chat NixOS module.
#
# Standalone Quickshell chat panel for the spaces AI agent
# (pi --mode rpc). Each chat session spawns its own pi process under
# a per-session systemd-run --user transient service, so multiple
# conversations stream in parallel and each lives in its own
# filesystem sandbox (ProtectHome=tmpfs + selective binds).
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
#   ~/.local/state/spaces/pi/pi-agent/         (pi config dir, settings.json + auth.json + models.json)
#   ~/.local/state/spaces/pi/sessions/         (one subdir per chat — pi --session-dir target)
#   ~/.local/share/spaces/workspaces/          (default per-chat cwd, picked by the shell)
#   /run/spaces-secrets/openrouter-api-key     (when openrouter.enable = true; user-readable)
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
  piPkg = cfg.piPackage;

  # Memory extension: nix derivation that substitutes the absolute
  # sediment binary path into a single-file pi extension. Path-typed
  # so the existing extensions-loading logic treats it like any other
  # bundled extension.
  memoryExtensionPkg = pkgs.callPackage ./extensions/memory { sediment = sedimentPkg; };

  shellDir = ../../../programs/pi-chat;
  shellName = "pi-chat";

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
  piAgentRel = "${stateRel}/pi-agent";
  sessionsRel = "${stateRel}/sessions";
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
  memoryHfHome = sedimentPkg.modelCache;

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

  piSettings = cfg.piSettings // {
    inherit (cfg) defaultProvider;
    inherit (cfg) defaultModel;
    quietStartup = true;
    extensions = lib.attrValues resolvedEnabledExtensions;
    skills = lib.attrValues allSkills;
  };

  piSettingsJson = jsonFormat.generate "pi-chat-settings.json" piSettings;

  # Allowlist of regex patterns whose bash invocations skip the
  # bash-confirm prompt. The bash-confirm extension reads this file at
  # load from $PI_CODING_AGENT_DIR/bash-confirm.json — keep the name in
  # sync with modules/nixos/pi-chat/extensions/bash-confirm.ts.
  bashConfirmJson = jsonFormat.generate "pi-chat-bash-confirm.json" {
    inherit (cfg.bashConfirm) allowPatterns;
  };
  piModelsJson = jsonFormat.generate "pi-chat-models.json" cfg.piModels;

  piAuthJson = jsonFormat.generate "pi-chat-auth.json" {
    openrouter = {
      type = "api_key";
      # The plugin spawns each scope with LoadCredential=, which sets
      # $CREDENTIALS_DIRECTORY for the pi process. Pi's "!cat …"
      # indirection is evaluated at request time, so the key never
      # lands on disk inside the agent dir.
      key = ''!cat "$CREDENTIALS_DIRECTORY/openrouter-api-key"'';
    };
  };

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
  ];

  options.services.pi-chat = {
    enable = lib.mkEnableOption "pi-chat: standalone Quickshell chat panel for the spaces AI agent (pi --mode rpc)";

    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8012";
      description = "Base URL of an OpenAI-compatible LLM server (without /v1 suffix).";
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "gemma4:e4b";
      description = ''
        Model pi selects at session start. Must be served by the
        OpenAI-compatible endpoint at `llmUrl` (i.e. configured in
        `services.llama-swap.settings.models`). The full model list
        shown in the model picker is discovered at runtime from
        `''${llmUrl}/v1/models` by the llama-swap-discover extension.
      '';
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = ''
        Provider pi selects at session start. The local default is
        "local" — populated by the llama-swap-discover extension from
        the llama-swap endpoint. Set to "openrouter" (or any other
        bundled pi provider) to route chat through that backend.
      '';
    };

    piPackage = lib.mkOption {
      type = lib.types.package;
      default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
      defaultText = lib.literalExpression "inputs.llm-agents.packages.\${pkgs.stdenv.hostPlatform.system}.pi";
      description = "The pi coding agent package.";
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

    sandboxBinds = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.str;
              description = ''
                Host path to bind into the per-session pi sandbox. May
                contain systemd specifiers `%h` (user `$HOME`) and `%t`
                (`$XDG_RUNTIME_DIR`); both are expanded by the panel at
                session-spawn time.
              '';
            };
            target = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Path inside the sandbox the source is bound to. Same
                specifier expansion as `source`. When null (the default),
                the source path is reused on both sides.
              '';
            };
            mode = lib.mkOption {
              type = lib.types.enum [
                "ro"
                "rw"
              ];
              default = "ro";
              description = ''
                `ro` → systemd `BindReadOnlyPaths=`; `rw` → `BindPaths=`.
                Default `ro` because skills almost always only need to
                read configuration and data they did not produce.
              '';
            };
            optional = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                When true, prefix the bind source with `-` so systemd
                skips the entry instead of refusing to start the sandbox
                when the host path is missing. Use for sockets whose
                publisher may legitimately be down (e.g. a forwarder
                service that hasn't booted yet).
              '';
            };
          };
        }
      );
      default = [ ];
      example = lib.literalExpression ''
        [
          { source = "%t/signal-cli/socket"; mode = "rw"; }
          { source = "%h/.local/state/spaces/signal"; mode = "rw"; }
          { source = "%h/.local/share/signal-cli/attachments"; mode = "ro"; }
        ]
      '';
      description = ''
        Extra bind-mounts to inject into each per-session pi sandbox.

        NixOS modules that add a skill **MUST** publish their required
        host paths through this option rather than patching the
        pi-chat plugin's internal bind list. The panel resolves these
        at session-spawn time and appends the corresponding
        systemd-run `--property=BindPaths` / `--property=BindReadOnlyPaths`
        flags after the pi-chat-owned baseline binds.
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
        Extra keys to merge into pi's generated settings.json.
        `defaultProvider`, `defaultModel`, `extensions`, and `skills`
        are populated by this module and cannot be overridden here.
      '';
    };

    piModels = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      description = ''
        Contents of pi's models.json. Used to add custom providers or
        override model properties via `modelOverrides`. Empty by
        default — pi-chat ships no models.json when this is `{}`.
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
    assertions = [
      {
        assertion = !cfg.openrouter.enable || cfg.openrouter.apiKeyFile != null;
        message = "services.pi-chat.openrouter.apiKeyFile must be set when openrouter.enable = true.";
      }
    ];

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
    ];

    # llama-swap supplies the default LLM endpoint; enable by default
    # so a fresh install boots into a usable state.
    services.llama-swap.enable = lib.mkDefault true;

    # Every built-in skill's CLI lands on the system PATH. Two reasons:
    #   1. The chat shell forwards its own PATH into the pi-chat
    #      sandbox via `systemd-run --setenv=PATH=`, so the agent can
    #      shell out by bare name (`signal threads`, `osm-cli search …`,
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
      # Convenience wrapper for compositor keybinds:
      #     bind = Super+Space, pi-chat-toggle
      # All it does is invoke the IPC; kept in /run/current-system/sw
      # so it's discoverable on PATH.
      (pkgs.writeShellScriptBin "pi-chat-toggle" ''
        exec ${pkgs.quickshell}/bin/quickshell ipc -c ${shellName} call ${shellName} "''${1:-toggle}"
      '')
    ];

    environment.sessionVariables = {
      # sediment stashes its access.db alongside (i.e. in the parent
      # of) SEDIMENT_DB. The sandbox only bind-mounts the leaf
      # `memoryDbRel` dir RW, so SEDIMENT_DB has to point at a
      # subdirectory of it — that way both the LanceDB tree and the
      # access.db sibling land inside the bind mount.
      SEDIMENT_DB = "$HOME/${memoryDbRel}/data";
    };

    # Materialize pi's config dir into user state. Symlinking from a
    # /nix/store JSON keeps the file world-readable and tied to the
    # current system generation; pi reads it on every spawn.
    systemd.user.tmpfiles.rules = [
      "d %h/.local 0755 - - -"
      "d %h/.local/state 0755 - - -"
      "d %h/.local/state/spaces 0755 - - -"
      "d %h/${stateRel} 0755 - - -"
      "d %h/${piAgentRel} 0755 - - -"
      "d %h/${sessionsRel} 0755 - - -"
      "d %h/.local/share 0755 - - -"
      "d %h/.local/share/spaces 0755 - - -"
      "d %h/${workspacesRel} 0755 - - -"
      # An empty sessions.json so the plugin can read it on first
      # launch without a special-case branch.
      ''f %h/${sessionsIndexRel} 0644 - - - {"version":1,"sessions":[],"activeSessionId":null}''
      "L+ %h/${piAgentRel}/settings.json - - - - ${piSettingsJson}"
      "L+ %h/${piAgentRel}/bash-confirm.json - - - - ${bashConfirmJson}"
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
    ++ lib.optional (cfg.piModels != { }) "L+ %h/${piAgentRel}/models.json - - - - ${piModelsJson}"
    ++ lib.optional cfg.openrouter.enable "L+ %h/${piAgentRel}/auth.json - - - - ${piAuthJson}"
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
    systemd.services.spaces-secrets-load = lib.mkIf cfg.openrouter.enable {
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
        install -m 0640 -o root -g users \
          ${cfg.openrouter.apiKeyFile} \
          /run/spaces-secrets/openrouter-api-key
      '';
    };

    # Shell config file. The QML side reads this on startup so we
    # don't have to thread a dozen env vars through the user manager.
    # Symlink from a generation-pinned store path.
    environment.etc."spaces/pi-chat.json".source = jsonFormat.generate "pi-chat-shell.json" {
      inherit (cfg) llmUrl;
      inherit (cfg) defaultModel;
      inherit (cfg) defaultProvider;
      piBin = lib.getExe piPkg;
      inherit (cfg.sandbox) idleTimeoutMinutes;
      inherit (cfg.sandbox) memoryHigh;
      openrouterEnabled = cfg.openrouter.enable;
      # memoryDbDir is $HOME-relative (the user-writable vector store);
      # memoryHfHome is the absolute /nix/store path that ships the
      # pre-baked embedding-model cache. The per-chat memory toggle
      # in the panel header writes/removes a marker file under each
      # session's state dir, so both paths stay live regardless.
      memoryDbDir = memoryDbRel;
      memoryHfHome = toString memoryHfHome;
      # Extra sandbox binds contributed via services.pi-chat.sandboxBinds.
      # The panel expands %h / %t and emits one systemd-run BindPaths
      # (or BindReadOnlyPaths) property per entry, after the
      # pi-chat-owned baseline binds.
      inherit (cfg) sandboxBinds;
    };

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
      Exec=${pkgs.systemd}/bin/systemctl --user start pi-chat.service
      X-GNOME-Autostart-enabled=true
      OnlyShowIn=niri;sway;Hyprland;river;KDE;
    '';
  };
}
