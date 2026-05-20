# Pi-chat NixOS module.
#
# Drives the noctalia chat plugin against pi --mode rpc directly.
# One pi process per chat session is spawned by the plugin under a
# per-session systemd-run --user transient service, so several
# conversations can stream in parallel and each one lives in its own
# filesystem sandbox (ProtectHome=tmpfs + selective binds).
#
# Files this module owns:
#   ~/.local/state/distro/pi/pi-agent/         (pi config dir, settings.json + auth.json + models.json)
#   ~/.local/state/distro/pi/sessions/         (one subdir per chat — pi --session-dir target)
#   ~/.local/share/distro/workspaces/          (default per-chat cwd, picked by the plugin)
#   /run/distro-secrets/openrouter-api-key     (when openrouter.enable = true; user-readable)
#
# User systemd units:
#   distro-skill-config-daemon.service         (skill-config IPC, $XDG_RUNTIME_DIR/distro-skill-config.sock)
#   distro-notify-forward.service              (D-Bus notifications -> noctalia plugin IPC)
#   distro-location-update.service + timer     (geoclue -> $XDG_RUNTIME_DIR/distro/location.json)
#
# The plugin itself is enabled via services.pi-chat.noctaliaPlugin
# (on by default). The module is otherwise self-contained.
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

  piPkg = cfg.piPackage;

  pluginDir = ../../../programs/pi-chat-plugin;
  pluginId = "pi-chat";

  # State paths use systemd tmpfiles' %h/%t substitutions when written
  # via systemd.user.tmpfiles. For module-internal use we keep the
  # literal expansions that tmpfiles understands.
  stateRel = ".local/state/distro/pi";
  workspacesRel = ".local/share/distro/workspaces";
  piAgentRel = "${stateRel}/pi-agent";
  sessionsRel = "${stateRel}/sessions";
  sessionsIndexRel = "${stateRel}/sessions.json";
  skillsDefsRel = "${stateRel}/skills-defs";
  skillConfigStoreRel = "${stateRel}/skill-config";

  # All skills (built-ins + user-supplied via cfg.skills), merged into
  # one linked-farm so the plugin can pass a single dir or pi can read
  # each one by absolute path from settings.json.
  builtinSkills = {
    datetime = "${skillsDir}/datetime";
    location = "${skillsDir}/location";
    maps = "${skillsDir}/maps";
    skill-config = "${skillsDir}/skill-config";
    calendar = "${skillsDir}/calendar";
  };
  allSkills = builtinSkills // cfg.skills;

  # Pi extensions: bool means "use the bundled .ts shipped here"; path
  # means use that file/dir verbatim.
  bundledExtensions = {
    bash-confirm = ./extensions/bash-confirm.ts;
    llama-swap-discover = ./extensions/llama-swap-discover.ts;
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

  # D-Bus notification forwarder. Posts incoming notifications into the
  # active chat session via noctalia's plugin IPC. The plugin's `send`
  # verb already exists and is unchanged.
  notifScript = pkgs.writeShellScript "distro-notify-forward" ''
    set -u
    export PATH="${
      lib.makeBinPath [
        pkgs.dbus
        pkgs.coreutils
        pkgs.gnused
      ]
    }:$PATH"

    NOCTALIA="${cfg.noctaliaShellBin}"

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

    dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'" |
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
                 "$NOCTALIA" ipc call plugin:${pluginId} send "$text" || true
               fi
               ;;
          esac
          ;;
      esac
    done
  '';

  locationScript = pkgs.writeShellScript "distro-location-update" ''
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

    out_dir="''${XDG_RUNTIME_DIR}/distro"
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
  options.services.pi-chat = {
    enable = lib.mkEnableOption "pi-chat: noctalia chat plugin driving pi --mode rpc directly";

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

    noctaliaShellBin = lib.mkOption {
      type = lib.types.str;
      default = "noctalia-shell";
      description = ''
        Binary name (or absolute path) used by the notification
        forwarder to invoke noctalia IPC. Override only when running
        a custom build outside the user's PATH.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Additional skill directories for pi, keyed by name. Merged
        with the built-in distro skills (datetime, location, maps,
        skill-config, calendar).
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
          line). Loaded into /run/distro-secrets/openrouter-api-key by
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
          "distro-chat"
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

    noctaliaPlugin = lib.mkEnableOption "symlink the noctalia chat plugin into user config dirs" // {
      description = ''
        When enabled, this module owns the
        `~/.config/noctalia/plugins/${pluginId}` symlink.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.openrouter.enable || cfg.openrouter.apiKeyFile != null;
        message = "services.pi-chat.openrouter.apiKeyFile must be set when openrouter.enable = true.";
      }
    ];

    # llama-swap supplies the default LLM endpoint; enable by default
    # so a fresh install boots into a usable state.
    services.llama-swap.enable = lib.mkDefault true;

    # Skill-config CLI on PATH so pi (running as the interactive user)
    # can `bash` it without going through nix-shell.
    environment.systemPackages = [ skillConfigPkg ];

    # Materialize pi's config dir into user state. Symlinking from a
    # /nix/store JSON keeps the file world-readable and tied to the
    # current system generation; pi reads it on every spawn.
    systemd.user.tmpfiles.rules = [
      "d %h/.local 0755 - - -"
      "d %h/.local/state 0755 - - -"
      "d %h/.local/state/distro 0755 - - -"
      "d %h/${stateRel} 0755 - - -"
      "d %h/${piAgentRel} 0755 - - -"
      "d %h/${sessionsRel} 0755 - - -"
      "d %h/.local/share 0755 - - -"
      "d %h/.local/share/distro 0755 - - -"
      "d %h/${workspacesRel} 0755 - - -"
      # An empty sessions.json so the plugin can read it on first
      # launch without a special-case branch.
      ''f %h/${sessionsIndexRel} 0644 - - - {"version":1,"sessions":[],"activeSessionId":null}''
      "L+ %h/${piAgentRel}/settings.json - - - - ${piSettingsJson}"
      # skill-config CLI resolves schemas from $state_dir/skills-defs/<skill>/SKILL.md.
      # Symlink each skill so request-input can validate fields before
      # contacting the daemon.
      "d %h/${skillsDefsRel} 0755 - - -"
    ]
    ++ lib.mapAttrsToList (name: path: "L+ %h/${skillsDefsRel}/${name} - - - - ${path}") allSkills
    ++ [
      # skill-config stores per-skill config.toml / secrets.toml here.
      "d %h/${skillConfigStoreRel} 0755 - - -"
    ]
    ++ lib.optional (cfg.piModels != { }) "L+ %h/${piAgentRel}/models.json - - - - ${piModelsJson}"
    ++ lib.optional cfg.openrouter.enable "L+ %h/${piAgentRel}/auth.json - - - - ${piAuthJson}"
    ++ lib.optionals cfg.noctaliaPlugin [
      "d %h/.config/noctalia 0755 - - -"
      "d %h/.config/noctalia/plugins 0755 - - -"
      "d %h/.config/noctalia/plugins-autoload 0755 - - -"
    ];

    # ── User services ────────────────────────────────────────────────

    # Materialize the chat plugin into ~/.config/noctalia/plugins with
    # CURRENT mtimes. Symlinking the plugin dir from /nix/store would
    # be simpler, but Qt's qmlcache keys compiled bytecode by
    # (absolute path, source mtime). Every file under /nix/store has
    # mtime = 1970-01-01, so on each rebuild Qt thinks its cached
    # bytecode is still fresh and silently keeps the OLD plugin
    # (missing newly-added IpcHandler functions, etc.). Copying with
    # fresh mtimes invalidates the cache on every rebuild.
    systemd.user.services.distro-pi-chat-plugin-sync = lib.mkIf cfg.noctaliaPlugin {
      description = "Materialize pi-chat plugin with fresh mtimes (Qt qmlcache invalidation)";
      wantedBy = [ "default.target" ];
      # Run before any UI starts so noctalia spawn picks up the
      # refreshed plugin on its first load.
      before = [ "graphical-session-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        src=${pluginDir}
        dst="$HOME/.config/noctalia/plugins/${pluginId}"
        mkdir -p "$(dirname "$dst")" "$HOME/.config/noctalia/plugins-autoload"
        rm -rf "$dst"
        # cp without -p leaves mtimes at the current time.
        cp -rT "$src" "$dst"
        chmod -R u+w "$dst"
        # Make plugins-autoload point at the same materialized copy
        # so noctalia's autoload-driven enable-state stays in sync.
        ln -sfn "$dst" "$HOME/.config/noctalia/plugins-autoload/${pluginId}"
      '';
    };

    # Skill-config IPC daemon. Lives as a regular user systemd unit;
    # each pi-chat scope bind-mounts its socket at /run/distro/skill-config.sock.
    systemd.user.services.distro-skill-config-daemon = {
      description = "skill-config IPC daemon (pi-chat)";
      after = [ "default.target" ];
      wantedBy = [ "default.target" ];
      environment = {
        # Default socket lives in $XDG_RUNTIME_DIR so it's torn down
        # when the user session ends.
        SKILL_CONFIG_SOCKET = "%t/distro-skill-config.sock";
      };
      serviceConfig = {
        ExecStart = lib.getExe skillConfigDaemonPkg;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.user.services.distro-notify-forward = lib.mkIf cfg.notificationForwarding.enable {
      description = "Forward desktop notifications to the pi-chat panel";
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = notifScript;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.user.services.distro-location-update = lib.mkIf cfg.locationUpdates.enable {
      description = "Update pi-chat location via GeoClue";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = locationScript;
      };
    };
    systemd.user.timers.distro-location-update = lib.mkIf cfg.locationUpdates.enable {
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
    systemd.services.distro-secrets-load = lib.mkIf cfg.openrouter.enable {
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
        install -d -m 0750 -o root -g users /run/distro-secrets
        install -m 0640 -o root -g users \
          ${cfg.openrouter.apiKeyFile} \
          /run/distro-secrets/openrouter-api-key
      '';
    };

    # Plugin config file. The QML side reads this on startup so we
    # don't have to thread a dozen env vars through the user manager
    # (whose extraConfig is awkward to wedge into the noctalia
    # process tree). Symlink from a generation-pinned store path.
    environment.etc."distro/pi-chat.json".source = jsonFormat.generate "pi-chat-plugin.json" {
      inherit (cfg) llmUrl;
      inherit (cfg) defaultModel;
      inherit (cfg) defaultProvider;
      piBin = lib.getExe piPkg;
      inherit pluginId;
      inherit (cfg.sandbox) idleTimeoutMinutes;
      inherit (cfg.sandbox) memoryHigh;
      openrouterEnabled = cfg.openrouter.enable;
    };
  };
}
