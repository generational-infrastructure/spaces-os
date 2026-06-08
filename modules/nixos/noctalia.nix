# Noctalia-shell bar as a graphical-session systemd user service, plus
# a bundled `spaces-sessions` plugin pinned in the center bar that
# shows one icon per pi-chat agent session.
#
# An ExecStartPre seeds the user's ~/.config/noctalia: it deep-merges
# our managed JSON (top-level settings.json, plugins.json, and the
# plugin's own settings.json) and symlinks the plugin's QML into
# plugins/spaces-sessions/. Files stay writable so runtime edits and
# the in-app settings UI survive; keys we pin re-apply on every
# (re)start. Without an existing settings.json noctalia takes its
# fresh-install path and the bar fails to draw until a manual reload —
# seeding sidesteps that.
#
# Also keeps a purge that cleans up leftover state from the prior
# patched-build / spaces-plugin era.
{ pkgs, ... }:
let
  # Managed top-level settings.json. Pins bar position and the center
  # bar's widget list (Workspace pills + the bundled session indicator).
  # Merged, not symlinked, so the user can still change everything else
  # from the UI.
  managedSettings = (pkgs.formats.json { }).generate "noctalia-settings.json" {
    bar.position = "top";
    bar.widgets.center = [
      { id = "Workspace"; }
      { id = "plugin:spaces-sessions"; }
    ];
  };

  # Managed plugins.json — only forces our bundled plugin enabled. User
  # plugins and other `states.*` entries survive the deep merge.
  managedPlugins = (pkgs.formats.json { }).generate "noctalia-plugins.json" {
    states."spaces-sessions".enabled = true;
  };

  # Managed plugin settings — pins the absolute quickshell binary and
  # the pi-chat IPC target the indicator shells out to on click.
  managedSpacesSessionsSettings =
    (pkgs.formats.json { }).generate "noctalia-spaces-sessions-settings.json"
      {
        focusCommand = "${pkgs.quickshell}/bin/quickshell ipc -c pi-chat call pi-chat";
      };

  # The bundled plugin's source tree (manifest + QML). Copied into the
  # Nix store by path interpolation; we materialise it per-file under
  # ~/.config/noctalia/plugins/spaces-sessions/ at service start.
  spacesSessionsPluginSrc = ../../programs/noctalia-spaces-sessions;

  # Deep-merges each managed JSON file into ~/.config/noctalia/<rel>
  # (jq `a * b`, managed side wins): objects merge recursively, arrays /
  # scalars are replaced, unmanaged keys (and the user's runtime edits to
  # them) survive. Runs as the noctalia-shell ExecStartPre, so it executes
  # per-user with $HOME set, before the bar starts.
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

      # Materialise the bundled plugin: per-file symlinks under a real
      # plugins/<id>/ directory (NOT a single dir symlink — the
      # stale-plugin purge below sweeps top-level symlinks in plugins/,
      # and noctalia needs to write its own settings.json into that dir
      # at runtime). Per-file symlinks let manifest/QML track the store
      # while leaving settings.json a real, writable file.
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

      mergeNoctaliaJson ${managedSettings}                 "$cfgDir/settings.json"
      mergeNoctaliaJson ${managedPlugins}                  "$cfgDir/plugins.json"
      mergeNoctaliaJson ${managedSpacesSessionsSettings}   "$cfgDir/plugins/spaces-sessions/settings.json"
    '';
  };

  # Removes leftover spaces-owned plugin state on every nixos-rebuild
  # / boot activation: the patched-build `plugins-autoload/` dir, any
  # symlink under `plugins/` (spaces materialised plugins as symlinks,
  # marketplace installs are real dirs), and matching `plugins.json`
  # entries (by unlinked id, by autoload:true flag, or by historical
  # spaces id for hosts where the symlink was already gone).
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
  config = {
    environment.systemPackages = [
      pkgs.noctalia-shell
      pkgs.libnotify
      # Noctalia widgets shell out to wl-{copy,paste} and xdg-open by
      # bare name; ship the binaries on the system PATH.
      pkgs.wl-clipboard
      pkgs.xdg-utils
    ];

    # noctalia's Battery widget reads UPower over D-Bus.
    services.upower.enable = true;

    # Activation runs the purge on every rebuild and boot — no need
    # to wait for the noctalia-shell service to restart.
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
        # Seed/merge managed JSON into ~/.config/noctalia before the bar
        # starts (per-user, $HOME set).
        ExecStartPre = "${mergeConfig}/bin/noctalia-config-merge";
        ExecStart = "${pkgs.noctalia-shell}/bin/noctalia-shell";
        Restart = "on-failure";
        Slice = "session.slice";
        # Noctalia spawns helpers (`sh`, `wl-paste`, `voxtype`, …) by
        # bare name; the default user PATH only has /run/wrappers/bin.
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
