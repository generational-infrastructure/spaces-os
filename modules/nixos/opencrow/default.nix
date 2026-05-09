# Opinionated opencrow wrapper for local use with socket backend + Ollama LLM.
#
# Wraps the upstream services.opencrow NixOS module, providing:
# - Socket backend (local UNIX socket, no relay/keys needed)
# - Ollama provider with models.json auto-generation
# - Noctalia plugin installation (optional)
# The upstream opencrow NixOS module is imported by distro.nix.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.opencrow-local;

  stateDir = "/var/lib/opencrow-${cfg.instanceName}";

  skillsDir = ../../../skills;

  opencrowPkg = inputs.opencrow.packages.${pkgs.stdenv.hostPlatform.system}.opencrow;

  skillConfigPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config;
  skillConfigDaemonPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config-daemon;

  # All skills (built-ins + user-supplied via cfg.skills), merged once so we
  # can both pass them to the upstream module and materialise them as a
  # single linked-farm dir for skill-config to read SKILL.md from at the
  # same path on host and inside the container.
  allSkills = {
    web = "${opencrowPkg}/share/opencrow/skills/web";
    datetime = "${skillsDir}/datetime";
    location = "${skillsDir}/location";
    maps = "${skillsDir}/maps";
    skill-config = "${skillsDir}/skill-config";
    calendar = "${skillsDir}/calendar";
  }
  // cfg.skills;

  skillsFarm = pkgs.linkFarm "opencrow-${cfg.instanceName}-skills-defs" (
    lib.mapAttrsToList (name: path: { inherit name path; }) allSkills
  );

  discoverExtension = ./llama-swap-discover.ts;

  pluginDir = ../../../programs/opencrow-chat-plugin;

  locationDir = "/run/opencrow-location";

  # Notification forwarding: monitor D-Bus Notify calls and send them
  # to opencrow via the chat socket as regular messages.
  notifScript = pkgs.writeShellScript "opencrow-notify-forward" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.dbus
        pkgs.coreutils
        pkgs.socat
        pkgs.jq
      ]
    }:$PATH"
    SOCK="$XDG_RUNTIME_DIR/opencrow-chat.sock"

    # Colon-separated list of app names to ignore.
    IGNORED="${lib.concatStringsSep ":" (map lib.toLower cfg.notificationForwarding.ignoredApps)}"

    is_ignored() {
      local app IFS=':'
      app=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
      for i in $IGNORED; do
        [ "$app" = "$i" ] && return 0
      done
      return 1
    }

    # Wait for the chat socket to appear.
    while [ ! -S "$SOCK" ]; do sleep 5; done

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
                 msg=$(jq -cn --arg t "$text" '{cmd:"send",text:$t,type:"notification"}')
                 printf '%s\n' "$msg" | socat - UNIX-CONNECT:"$SOCK"
               fi
               ;;
          esac
          ;;
      esac
    done
  '';

  locationScript = pkgs.writeShellScript "opencrow-update-location" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.geoclue2
        pkgs.jq
        pkgs.coreutils
      ]
    }:$PATH"
    where_am_i="${pkgs.geoclue2}/libexec/geoclue-2.0/demos/where-am-i"
    out="${locationDir}/location.json"

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
  imports = [ ../opencrow-warmup.nix ];

  options.services.opencrow-local = {
    enable = lib.mkEnableOption "opencrow with local socket backend and Ollama LLM";

    instanceName = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = ''
        Name for the opencrow instance. The upstream module prefixes this
        with "opencrow-", so e.g. "geninf" yields container opencrow-geninf.
        Use "default" for the unprefixed name "opencrow".
      '';
    };

    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8012";
      description = "Base URL of an OpenAI-compatible LLM server (without /v1 suffix).";
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "gemma4:e2b";
      description = ''
        Model pi selects at session start. Must be served by the
        OpenAI-compatible endpoint at `llmUrl` (i.e. configured in
        `services.llama-swap.settings.models`). The full model list
        shown by `!models` is discovered at runtime from
        `''${llmUrl}/v1/models`.
      '';
    };

    socketName = lib.mkOption {
      type = lib.types.str;
      default = "OpenCrow";
      description = "Display name shown in status events.";
    };

    piPackage = lib.mkOption {
      type = lib.types.package;
      default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
      defaultText = lib.literalExpression "inputs.llm-agents.packages.\${pkgs.stdenv.hostPlatform.system}.pi";
      description = "The pi coding agent package.";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Environment files with secrets.";
    };

    credentialFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Systemd credential files passed to the container.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages available inside the container.";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Additional skill directories for pi, keyed by name. These are
        merged with the built-in distro skills (datetime).
      '';
    };

    extensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.bool lib.types.path);
      default = { };
      description = "Pi extensions to enable (true for bundled, path for custom).";
    };

    piSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra keys for pi's settings.json.";
    };

    notificationForwarding = {
      ignoredApps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "opencrow"
        ];
        description = "App names whose notifications are not forwarded (exact match).";
      };
    };

    noctaliaPlugin = lib.mkEnableOption "noctalia opencrow-chat panel plugin" // {
      description = ''
        Symlink the opencrow-chat QML plugin into each user's
        ~/.config/noctalia/plugins/opencrow-chat directory.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable llama-swap by default — opencrow-local's default llmUrl
    # points at llama-swap's port (8012).
    services.llama-swap.enable = lib.mkDefault true;

    # Prime the LLM prompt cache at boot. Lives in its own module so
    # the warmup machinery can be disabled independently.
    services.opencrow-warmup = {
      enable = lib.mkDefault true;
      inherit (cfg) instanceName;
    };
    # Host-accessible runtime dirs for the chat socket + location data.
    systemd.tmpfiles.rules =
      let
        socketDir = "/run/opencrow-${cfg.instanceName}";
      in
      [
        # Host-accessible directory for the chat socket. The state dir
        # itself is 0750 (owned by the container's dynamic user), so we
        # put the socket in a separate world-accessible run dir and
        # bind-mount it into the container.
        "d ${socketDir} 0777 root root -"
        "d ${socketDir}/attachments 0777 root root -"
        # Location data directory, writable by user services, readable
        # by the container.
        "d ${locationDir} 0777 root root -"
        # Skill schemas: skill-config reads SKILL.md frontmatter from here
        # at the same path on host and inside the container.
        "L+ ${stateDir}/skills-defs - - - - ${skillsFarm}"
        # Per-instance config + secrets store, owned by the opencrow user.
        "d ${stateDir}/skill-config 0750 opencrow opencrow -"
        "f ${stateDir}/skill-config/config.toml 0644 opencrow opencrow -"
        "f ${stateDir}/skill-config/secrets.toml 0600 opencrow opencrow -"
      ];

    # skill-config on the host PATH for occasional `sudo -u opencrow
    # skill-config …` debugging or manual edits. The agent-driven flow
    # inside the container is the primary path; this is a fallback.
    environment.systemPackages = [ skillConfigPkg ];

    # Sidecar daemon inside the opencrow container. The upstream
    # services.opencrow.instances.<name> module sets containers.<container>.config
    # inline; NixOS module merging lets us add another systemd service to the
    # same container's config from outside without modifying upstream.
    containers."opencrow-${cfg.instanceName}".config = _: {
      systemd.services.skill-config-daemon = {
        description = "skill-config IPC daemon for opencrow (${cfg.instanceName})";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        environment.SKILL_CONFIG_SOCKET = "/run/opencrow-sock/skill-config.sock";
        serviceConfig = {
          ExecStart = lib.getExe skillConfigDaemonPkg;
          Restart = "on-failure";
          RestartSec = 5;
          User = "opencrow";
          Group = "opencrow";
        };
      };
    };

    # Periodically update the location file via GeoClue. Runs as a
    # user service because GeoClue requires a D-Bus agent for
    # authorization, which is only available in user sessions.
    systemd.user.services.opencrow-location = {
      description = "Update opencrow location via GeoClue";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = locationScript;
      };
    };
    systemd.user.timers.opencrow-location = {
      description = "Periodically update opencrow location";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "30s";
        OnUnitActiveSec = "10min";
      };
    };

    # Plugin symlink for every user session.
    systemd.user.tmpfiles.rules = lib.optionals cfg.noctaliaPlugin [
      "d %h/.config/noctalia/plugins 0755 - - -"
      "L+ %h/.config/noctalia/plugins/opencrow-chat - - - - ${pluginDir}"
      # Also symlink into autoload dir so the patched noctalia auto-enables it.
      "d %h/.config/noctalia/plugins-autoload 0755 - - -"
      "L+ %h/.config/noctalia/plugins-autoload/opencrow-chat - - - - ${pluginDir}"
    ];

    # Symlink opencrow's socket and clear stale QML cache on plugin updates.
    # Runs as a user service since XDG_RUNTIME_DIR is per-user.
    systemd.user.services.opencrow-socket-link = lib.mkIf cfg.noctaliaPlugin {
      description = "Symlink opencrow chat socket for noctalia plugin";
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      # Restart when the plugin store path changes (triggers QML cache clear).
      restartTriggers = [ "${pluginDir}" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "link-opencrow-socket" ''
          ln -sf /run/opencrow-${cfg.instanceName}/chat.sock "$XDG_RUNTIME_DIR/opencrow-chat.sock"
          ln -sf /run/opencrow-${cfg.instanceName}/attachments "$XDG_RUNTIME_DIR/opencrow-chat-attachments"
          # Clear QML cache so noctalia picks up updated plugin files.
          rm -rf "''${XDG_CACHE_HOME:-$HOME/.cache}/noctalia-qs/qmlcache" \
                 "''${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/qmlcache"
        '';
        ExecStop = "${pkgs.coreutils}/bin/rm -f %t/opencrow-chat.sock %t/opencrow-chat-attachments";
      };
    };

    systemd.user.services.opencrow-notify-forward = {
      description = "Forward desktop notifications to opencrow trigger pipe";
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = notifScript;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    services.opencrow.instances.${cfg.instanceName} = {
      enable = true;
      skills = allSkills;

      extraPackages = [
        inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.osm-cli
        inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.caldav-cli
        skillConfigPkg
        skillConfigDaemonPkg
      ]
      ++ cfg.extraPackages;

      inherit (cfg)
        piPackage
        environmentFiles
        credentialFiles
        piSettings
        ;

      extensions = cfg.extensions // {
        llama-swap-discover = discoverExtension;

      };

      # Bind-mount the host socket dir into the container so opencrow
      # can create the socket and the host user can connect to it.
      extraBindMounts."/run/opencrow-sock" = {
        hostPath = "/run/opencrow-${cfg.instanceName}";
        isReadOnly = false;
      };
      # Location data from the host's GeoClue service.
      extraBindMounts."/run/opencrow-location" = {
        hostPath = locationDir;
        isReadOnly = true;
      };

      environment = {
        OPENCROW_BACKEND = "socket";
        OPENCROW_SOCKET_PATH = "/run/opencrow-sock/chat.sock";
        OPENCROW_SOCKET_NAME = cfg.socketName;
        OPENCROW_PI_PROVIDER = "local";
        LLAMA_SWAP_BASE_URL = cfg.llmUrl;
        OPENCROW_PI_MODEL = cfg.defaultModel;
        OPENCROW_PI_IDLE_TIMEOUT = "1h";
        OPENCROW_SOUL_FILE = "${pluginDir}/SOUL.md";
        OPENCROW_LOG_LEVEL = "info";
        # skill-config reads these to find the per-instance state dir.
        OPENCROW_INSTANCE = cfg.instanceName;
        OPENCROW_STATE_DIR = stateDir;
      }
      // cfg.extraEnvironment;
    };
  };
}
