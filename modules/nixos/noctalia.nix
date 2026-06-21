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
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Managed top-level settings.json. Pins bar position and the center
  # bar's widget list (Workspace pills + the bundled session indicator).
  # Merged, not symlinked, so the user can still change everything else
  # from the UI.
  managedSettings = (pkgs.formats.json { }).generate "noctalia-settings.json" {
    bar.position = config.services.noctalia.bar.position;
    bar.widgets.center = [
      { id = "Workspace"; }
      { id = "plugin:voice-indicator"; }
      { id = "plugin:spaces-sessions"; }
    ];
    # Matte glass bar, per the design: a translucent surface (here the Kin
    # white) floating over a compositor blur of the wallpaper. noctalia's
    # default 0.93 is near-opaque; 0.7 matches the design's rgba(255,255,255,
    # 0.7). `enableBlurBehind` is the frosted blur behind the bar/panels/dock
    # (on by default — pinned so the glass effect is guaranteed; it needs a
    # compositor that supports the blur protocol, else it degrades to a clean
    # translucent strip).
    bar.backgroundOpacity = 0.7;
    general.enableBlurBehind = true;
    # Matte glass dock, per the design: a floating bottom dock of app icons,
    # translucent over the same compositor blur as the bar. noctalia's dock is
    # on by default; we float it and drop its opacity to the bar's 0.7 so the
    # glass matches, but leave it auto-hiding (noctalia's default) so it tucks
    # away until you reach the screen edge — the design mock shows it visible,
    # but always-on permanently reserves screen space. `pinnedApps` is left
    # empty — the dock shows running apps, and the Spaces pinned-app set isn't
    # fixed here; populate it with desktop-entry ids (e.g. "firefox.desktop").
    dock.enabled = true;
    dock.dockType = "floating";
    dock.displayMode = "auto_hide";
    dock.backgroundOpacity = 0.7;
    # Default the whole desktop to the Kin / Spaces OS colour scheme (light).
    # noctalia's ColorSchemeService resolves this name to the `Kin` scheme
    # materialised below, then writes ~/.config/noctalia/colors.json — the
    # file both the bar and the pi-chat panel (Commons/Color.qml) read. Pinned
    # like the other managed keys, so it re-applies on (re)start; the panel's
    # Color.qml keeps its Noctalia-default fallback for when colors.json is
    # absent. `useWallpaperColors = false` stops a wallpaper recolour from
    # overriding the brand palette.
    colorSchemes.predefinedScheme = "Kin";
    colorSchemes.useWallpaperColors = false;
    colorSchemes.darkMode = false;
    # Match the panel: the bar wears the design-system faces too. Inter for
    # the UI, DM Mono for clocks / metadata. Both are installed system-wide
    # by nixosModules.spaces (fonts.packages in spaces.nix).
    ui.fontDefault = "Inter";
    ui.fontFixed = "DM Mono";
  };

  # The Kin light palette as noctalia's 16 M3 role colours — white canvas,
  # near-black ink, the teal-slate "Clan" accent, success-green / magenta /
  # info-blue semantics. Shared between the scheme's `light` variant and the
  # seeded colors.json below so they can't drift.
  kinLight = {
    mPrimary = "#345253"; # clan-primary-700 — teal-slate accent
    mOnPrimary = "#ffffff";
    mSecondary = "#06aaf1"; # info blue — links / focus
    mOnSecondary = "#ffffff";
    mTertiary = "#17b239"; # success green — online / connected
    mOnTertiary = "#ffffff";
    mError = "#d75d9f"; # destructive magenta
    mOnError = "#ffffff";
    mSurface = "#ffffff"; # white canvas — the matte-glass bar/dock surface
    mOnSurface = "#171717"; # ink-900 body text
    mSurfaceVariant = "#f3f3f3"; # ink-100 wells / cards / peer bubbles
    mOnSurfaceVariant = "#6b6b6b"; # ink-500 muted text
    mOutline = "#ebebeb"; # ink-200 hairline
    mShadow = "#0d1416"; # clan-secondary-950 (noctalia applies alpha)
    mHover = "#ebebeb"; # quiet grey hover fill
    mOnHover = "#171717";
  };

  # Seed ~/.config/noctalia/colors.json directly with the Kin light palette.
  # The bar and the pi-chat panel read colors.json, but noctalia only rewrites
  # it when it *applies* a scheme — so on a host that already has a dark
  # colors.json the bar would stay dark until a manual re-apply. Seeding it
  # (deep-merged, managed wins) guarantees the light matte from first start;
  # noctalia's own apply writes the same values, so there's no conflict.
  kinColorsJson = (pkgs.formats.json { }).generate "noctalia-colors.json" kinLight;

  # The Kin / Spaces OS colour scheme, in noctalia's scheme format
  # ({ light, dark } of M3 role colours + a terminal block). The dark variant
  # keeps the brand for a manual light/dark toggle.
  kinColorScheme = (pkgs.formats.json { }).generate "Kin.json" {
    light = kinLight // {
      terminal = {
        normal = {
          black = "#171717";
          red = "#d75d9f";
          green = "#17b239";
          yellow = "#8a9b6f";
          blue = "#06aaf1";
          magenta = "#c43e81";
          cyan = "#4f747a";
          white = "#6b6b6b";
        };
        bright = {
          black = "#9ea39e";
          red = "#d75d9f";
          green = "#17b239";
          yellow = "#a6b58e";
          blue = "#5cc6f5";
          magenta = "#d75d9f";
          cyan = "#4f747a";
          white = "#171717";
        };
        foreground = "#171717";
        background = "#ffffff";
        selectionFg = "#ffffff";
        selectionBg = "#345253";
        cursorText = "#ffffff";
        cursor = "#345253";
      };
    };
    dark = {
      mPrimary = "#bae6ff"; # kin sky — accent on dark
      mOnPrimary = "#0d1416";
      mSecondary = "#06aaf1";
      mOnSecondary = "#0d1416";
      mTertiary = "#17b239";
      mOnTertiary = "#0d1416";
      mError = "#d75d9f";
      mOnError = "#0d1416";
      mSurface = "#0d1416"; # clan-secondary-950 ground
      mOnSurface = "#f7f9fa"; # clan-secondary-50 text
      mSurfaceVariant = "#142022";
      mOnSurfaceVariant = "#afc6ca"; # clan-secondary-300
      mOutline = "#2c4347"; # clan-secondary-900
      mShadow = "#000000";
      mHover = "#1c2c2f";
      mOnHover = "#f7f9fa";
      terminal = {
        normal = {
          black = "#142022";
          red = "#d75d9f";
          green = "#17b239";
          yellow = "#8a9b6f";
          blue = "#06aaf1";
          magenta = "#c43e81";
          cyan = "#afc6ca";
          white = "#f7f9fa";
        };
        bright = {
          black = "#2c4347";
          red = "#d75d9f";
          green = "#17b239";
          yellow = "#a6b58e";
          blue = "#5cc6f5";
          magenta = "#d75d9f";
          cyan = "#afc6ca";
          white = "#ffffff";
        };
        foreground = "#f7f9fa";
        background = "#0d1416";
        selectionFg = "#0d1416";
        selectionBg = "#bae6ff";
        cursorText = "#0d1416";
        cursor = "#bae6ff";
      };
    };
  };

  # Managed plugins.json — only forces our bundled plugin enabled. User
  # plugins and other `states.*` entries survive the deep merge.
  managedPlugins = (pkgs.formats.json { }).generate "noctalia-plugins.json" {
    states."spaces-sessions".enabled = true;
    states."voice-indicator".enabled = true;
  };

  # Managed plugin settings — pins the absolute quickshell binary and
  # the pi-chat IPC target the indicator shells out to on click.
  managedSpacesSessionsSettings =
    (pkgs.formats.json { }).generate "noctalia-spaces-sessions-settings.json"
      {
        focusCommand = "${pkgs.quickshell}/bin/quickshell ipc -c pi-chat call pi-chat";
      };

  # Managed plugin settings — pins toggleCommand to the ABSOLUTE wrapper,
  # taken from the typed command set so it can't drift from what's
  # installed. The voice indicator shells out to it on click; voxtype /
  # notify-send resolve from the noctalia service PATH when it runs.
  managedVoiceIndicatorSettings =
    (pkgs.formats.json { }).generate "noctalia-voice-indicator-settings.json"
      {
        toggleCommand = "${config.services.spaces.commands.voice-record-toggle}/bin/spaces-voice-record-toggle";
        hideWhenIdle = false;
      };

  # The bundled plugin's source tree (manifest + QML). Copied into the
  # Nix store by path interpolation; we materialise it per-file under
  # ~/.config/noctalia/plugins/spaces-sessions/ at service start.
  spacesSessionsPluginSrc = ../../programs/noctalia-spaces-sessions;

  # The voice indicator's source tree (manifest + QML + i18n). Materialised
  # per-file under ~/.config/noctalia/plugins/voice-indicator/.
  voiceIndicatorPluginSrc = ../../programs/noctalia-voice-indicator;

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
      materializePluginFiles ${voiceIndicatorPluginSrc} "plugins/voice-indicator"

      # Materialise the Kin colour scheme into noctalia's writable scheme
      # dir. ColorSchemeService scans `colorschemes/` with `find -L -mindepth
      # 2`, so the file must sit at colorschemes/Kin/Kin.json; the symlink is
      # followed. settings.json (below) pins this scheme as the active one.
      mkdir -p "$cfgDir/colorschemes/Kin"
      ln -sfn ${kinColorScheme} "$cfgDir/colorschemes/Kin/Kin.json"

      mergeNoctaliaJson ${kinColorsJson}                   "$cfgDir/colors.json"
      mergeNoctaliaJson ${managedSettings}                 "$cfgDir/settings.json"
      mergeNoctaliaJson ${managedPlugins}                  "$cfgDir/plugins.json"
      mergeNoctaliaJson ${managedSpacesSessionsSettings}   "$cfgDir/plugins/spaces-sessions/settings.json"
      mergeNoctaliaJson ${managedVoiceIndicatorSettings}   "$cfgDir/plugins/voice-indicator/settings.json"
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
  # The shortcut commands noctalia spawns are wrappers built here. Importing
  # the module declares the dependency and supplies
  # `config.services.spaces.commands` used above.
  imports = [ ./spaces-commands.nix ];

  options.services.noctalia = {
    bar.position = lib.mkOption {
      # Deliberately only the horizontal edges: noctalia itself also knows
      # left/right, but vertical bars are untested with the pinned center
      # widget list (Workspace pills + spaces-sessions plugin).
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
