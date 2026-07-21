# Noctalia-shell bar as a graphical-session user service, with bundled
# spaces-sessions and voice-indicator plugins pinned in the center bar.
#
# An ExecStartPre seeds ~/.config/noctalia by deep-merging our managed JSON and
# symlinking plugin QML; without an existing settings.json noctalia takes its
# fresh-install path and the bar fails to draw until a manual reload.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.noctalia;

  # Managed top-level settings.json: pins bar position and the center widget list.
  # Merged (not symlinked) so the user can still change everything else from the UI.
  managedSettings = (pkgs.formats.json { }).generate "noctalia-settings.json" {
    bar.position = config.services.noctalia.bar.position;
    bar.widgets.center = [
      { id = "Workspace"; }
      { id = "plugin:voice-indicator"; }
      { id = "plugin:spaces-sessions"; }
    ];
  };

  # Managed plugins.json — only forces our bundled plugins enabled; user plugins
  # and other `states.*` entries survive the deep merge.
  managedPlugins = (pkgs.formats.json { }).generate "noctalia-plugins.json" {
    states."spaces-sessions".enabled = true;
    states."voice-indicator".enabled = true;
  };

  # Pins the absolute quickshell binary and pi-chat IPC target the indicator
  # shells out to on click.
  managedSpacesSessionsSettings =
    (pkgs.formats.json { }).generate "noctalia-spaces-sessions-settings.json"
      {
        focusCommand = "${pkgs.quickshell}/bin/quickshell ipc -c pi-chat call pi-chat";
      };

  # Pins toggleCommand to the absolute wrapper from the typed command set so it
  # can't drift from what's installed. barPulse (the whole-bar "recording" glow)
  # is a managed enable so the cue ships everywhere; barPulseIntensity stays an
  # unmanaged per-user knob.
  managedVoiceIndicatorSettings =
    (pkgs.formats.json { }).generate "noctalia-voice-indicator-settings.json"
      {
        toggleCommand = "${config.services.spaces.commands.voice-record-toggle}/bin/spaces-voice-record-toggle";
        hideWhenIdle = false;
        barPulse = true;
      };

  # Plugin source trees (manifest + QML), materialised per-file under
  # ~/.config/noctalia/plugins/<id>/ at service start.
  spacesSessionsPluginSrc = ../../programs/noctalia-spaces-sessions;
  voiceIndicatorPluginSrc = ../../programs/noctalia-voice-indicator;

  # Deep-merges each managed JSON into ~/.config/noctalia/<rel> (jq `a * b`,
  # managed side wins): objects merge recursively, arrays/scalars are replaced,
  # unmanaged keys survive. Runs as the ExecStartPre, per-user with $HOME set.
  mergeConfig = pkgs.writeShellApplication {
    name = "noctalia-config-merge";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      cfgDir="''${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"

      mergeNoctaliaJson() {
        local managed="$1" target="$2" existing merged tmp dir
        dir="$(dirname "$target")"
        mkdir -p "$dir"
        if [ -f "$target" ] && existing="$(jq -e . "$target" 2>/dev/null)"; then
          :
        else
          existing='{}'
        fi
        if ! merged="$(printf '%s' "$existing" | jq --slurpfile m "$managed" '. * $m[0]')"; then
          echo "noctalia: could not merge $target, leaving it untouched" >&2
          return 0
        fi
        tmp="$(mktemp "$dir/.noctalia-merge.XXXXXX")"
        printf '%s\n' "$merged" > "$tmp"
        mv "$tmp" "$target"
      }

      # Per-file symlinks under a real plugins/<id>/ dir (NOT a dir symlink: the
      # purge below sweeps top-level symlinks, and noctalia writes its own
      # settings.json here at runtime). Manifest/QML track the store; settings.json
      # stays a real writable file.
      materializePluginFiles() {
        local src="$1" rel="$2" dst f name
        dst="$cfgDir/$rel"
        mkdir -p "$dst"
        for f in "$src"/*; do
          name="$(basename "$f")"
          ln -sfn "$f" "$dst/$name"
        done
      }

      materializePluginFiles ${spacesSessionsPluginSrc} "plugins/spaces-sessions"
      materializePluginFiles ${voiceIndicatorPluginSrc} "plugins/voice-indicator"

      mergeNoctaliaJson ${managedSettings}                 "$cfgDir/settings.json"
      mergeNoctaliaJson ${managedPlugins}                  "$cfgDir/plugins.json"
      mergeNoctaliaJson ${managedSpacesSessionsSettings}   "$cfgDir/plugins/spaces-sessions/settings.json"
      mergeNoctaliaJson ${managedVoiceIndicatorSettings}   "$cfgDir/plugins/voice-indicator/settings.json"
    '';
  };

  # Removes leftover spaces-owned plugin state: the patched-build
  # `plugins-autoload/` dir, any symlink under `plugins/` (spaces plugins are
  # symlinks, marketplace installs are real dirs), and matching `plugins.json`
  # entries (by unlinked id, autoload:true flag, or historical spaces id).
  purgeStalePlugins = pkgs.writeShellApplication {
    name = "noctalia-purge-stale-plugins";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"
      [ -d "$cfg" ] || exit 0

      rm -rf -- "$cfg/plugins-autoload"

      declare -a stale_ids=()
      if [ -d "$cfg/plugins" ]; then
        while IFS= read -r -d "" path; do
          stale_ids+=("$(basename "$path")")
          rm -f -- "$path"
        done < <(find "$cfg/plugins" -mindepth 1 -maxdepth 1 -type l -print0)
      fi

      states="$cfg/plugins.json"
      [ -f "$states" ] || exit 0

      ids_json="[]"
      if [ "''${#stale_ids[@]}" -gt 0 ]; then
        ids_json=$(printf "%s\n" "''${stale_ids[@]}" | jq -R . | jq -s .)
      fi

      tmp=$(mktemp -- "$cfg/.plugins.XXXXXX.json")
      if jq --argjson stale "$ids_json" '
        ["pi-chat", "opencrow-chat", "opencrow-skill-config"] as $legacy |
        if has("states") then
          .states |= with_entries(select(
            ((.value.autoload // false) != true)
            and (.key as $k | $legacy | index($k) | not)
            and (.key as $k | $stale  | index($k) | not)
          ))
        else . end
      ' "$states" >"$tmp"; then
        mv -- "$tmp" "$states"
      else
        rm -f -- "$tmp"
      fi
    '';
  };
in
{
  # Supplies the shortcut wrappers noctalia spawns (config.services.spaces.commands).
  imports = [ ./spaces-commands.nix ];

  options.services.noctalia = {
    enable = lib.mkEnableOption "noctalia-shell Wayland bar user service";

    bar.position = lib.mkOption {
      # Horizontal edges only: vertical bars are untested with our pinned center
      # widget list.
      type = lib.types.enum [
        "top"
        "bottom"
      ];
      default = "top";
      description = ''
        Edge of the screen the noctalia bar sits on. Pins `bar.position`
        in the managed settings.json, which is re-applied on every
        noctalia-shell (re)start — so it overrides any position chosen
        in the in-app settings UI.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.noctalia-shell
      pkgs.libnotify
      # Noctalia widgets shell out to wl-{copy,paste} and xdg-open by bare name.
      pkgs.wl-clipboard
      pkgs.xdg-utils
    ];

    # noctalia's Battery widget reads UPower over D-Bus.
    services.upower.enable = true;

    # Purge on every rebuild and boot, not just on service restart.
    system.userActivationScripts.noctaliaPurgeStalePlugins = ''
      ${purgeStalePlugins}/bin/noctalia-purge-stale-plugins
    '';

    systemd.user.services.noctalia-shell = {
      description = "Noctalia Wayland desktop shell";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      restartTriggers = [
        pkgs.noctalia-shell
        mergeConfig
      ];
      serviceConfig = {
        ExecStartPre = "${mergeConfig}/bin/noctalia-config-merge";
        ExecStart = "${pkgs.noctalia-shell}/bin/noctalia-shell";
        Restart = "on-failure";
        Slice = "session.slice";
        # Noctalia spawns helpers (`sh`, `wl-paste`, `voxtype`, …) by bare name;
        # the default user PATH only has /run/wrappers/bin.
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
