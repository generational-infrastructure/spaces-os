# Cheap nix-eval contract for the noctalia bar shipped by the spaces
# bundle.
#
# Two things actually need testing here:
#   - the stale-plugin purge runs at activation time AND removes
#     every leftover shape a long-running host can carry (symlinks
#     under plugins/, the patched-era plugins-autoload/ dir, and
#     ghost entries in plugins.json), without touching user-installed
#     marketplace plugins or other state;
#   - the bundle boundary is intact: nixosModules.spaces ships the
#     bar, nixosModules.pi-chat does not.
#
# Everything else (ExecStart shape, partOf/wantedBy, package list,
# upower toggle) is one-line module config — a `nix build` of the
# system catches breakage there, no point re-asserting it here.
{ pkgs, inputs, ... }:
let
  baseModules = [
    {
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      boot.loader.grub.enable = false;
      system.stateVersion = "26.05";
    }
  ];

  mkSystem =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ extra;
    };

  spacesSystem = mkSystem [
    inputs.self.nixosModules.spaces
    { networking.hostName = "noctalia-spaces"; }
  ];

  panelOnlySystem = mkSystem [
    inputs.self.nixosModules.pi-chat
    { networking.hostName = "noctalia-absent"; }
  ];

  userActivation = spacesSystem.config.system.userActivationScripts.script or "";

in
pkgs.runCommand "spaces-noctalia-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit userActivation;
    panelOnlyHasNoctalia =
      if (panelOnlySystem.config.systemd.user.services.noctalia-shell or null) == null then
        "no"
      else
        "yes";
    spacesHasNoctalia =
      if (spacesSystem.config.systemd.user.services.noctalia-shell or null) == null then "no" else "yes";
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # ── 1. Bundle boundary ──────────────────────────────────────────
    [ "$spacesHasNoctalia"    = "yes" ] || fail "nixosModules.spaces must declare the noctalia-shell user unit"
    [ "$panelOnlyHasNoctalia" = "no"  ] || fail "nixosModules.pi-chat alone must not pull noctalia in"

    # ── 2. Purge is wired into per-user activation (so nixos-rebuild
    # switch alone is enough — no service restart required). The
    # snippet name keeps the assertion specific to our own fragment
    # rather than any random reference to the binary.
    case "$userActivation" in
      *"snippet noctaliaPurgeStalePlugins"*"/bin/noctalia-purge-stale-plugins"*) ;;
      *) fail "system.userActivationScripts.noctaliaPurgeStalePlugins is not wired into the merged activation script" ;;
    esac

    # Pull the absolute path of the purge binary out of the merged
    # activation script so we can exercise it below.
    purgeScript=$(printf '%s\n' "$userActivation" \
      | grep -oE '/nix/store/[^[:space:]]+/bin/noctalia-purge-stale-plugins' \
      | head -n1)
    [ -x "$purgeScript" ] || fail "could not resolve purge binary from activation script"

    # ── 3. Purge behaviour ──────────────────────────────────────────
    # Stage every leftover shape a host could carry across the
    # autoload / pre-autoload / rename eras, mixed with a real
    # marketplace install that MUST survive untouched.
    stage=$(mktemp -d)
    export HOME="$stage"
    cfg="$HOME/.config/noctalia"
    mkdir -p "$cfg/plugins" "$cfg/plugins-autoload/pi-chat" \
             "$cfg/plugins/user-weather" \
             "$stage/fake-store/pi-chat" \
             "$stage/fake-store/opencrow-chat" \
             "$stage/fake-store/opencrow-skill-config"
    ln -s "$stage/fake-store/pi-chat"               "$cfg/plugins/pi-chat"
    ln -s "$stage/fake-store/opencrow-chat"         "$cfg/plugins/opencrow-chat"
    ln -s "$stage/fake-store/opencrow-skill-config" "$cfg/plugins/opencrow-skill-config"
    cat >"$cfg/plugins.json" <<'EOF'
    {
      "version": 2,
      "states": {
        "pi-chat":               { "enabled": true, "autoload": true },
        "opencrow-chat":         { "enabled": true },
        "opencrow-skill-config": { "enabled": true },
        "legacy-autoload":       { "enabled": true, "autoload": true },
        "user-weather":          { "enabled": true }
      },
      "sources": [
        { "name": "Noctalia Plugins",
          "url":  "https://github.com/noctalia-dev/noctalia-plugins",
          "enabled": true }
      ]
    }
    EOF

    "$purgeScript"

    [ ! -e "$cfg/plugins-autoload" ] || fail "purge left plugins-autoload/ behind"
    for ghost in pi-chat opencrow-chat opencrow-skill-config; do
      [ ! -L "$cfg/plugins/$ghost" ] && [ ! -e "$cfg/plugins/$ghost" ] \
        || fail "purge left plugins/$ghost behind"
    done
    [ -d "$cfg/plugins/user-weather" ] \
      || fail "purge wiped user-installed plugins/user-weather/ — must only touch symlinks"

    for ghost in pi-chat opencrow-chat opencrow-skill-config legacy-autoload; do
      jq -e --arg k "$ghost" '.states | has($k) | not' "$cfg/plugins.json" >/dev/null \
        || fail "purge left states.$ghost in plugins.json"
    done
    jq -e '.states["user-weather"].enabled == true' "$cfg/plugins.json" >/dev/null \
      || fail "purge dropped user-installed plugins.json entry (must only drop spaces-owned ids)"

    # ── 4. Fresh host is a no-op. Catches a regression where the
    # purge errors when ~/.config/noctalia does not exist yet.
    HOME=$(mktemp -d) "$purgeScript" \
      || fail "purge errored on a host with no ~/.config/noctalia"

    touch "$out"
  ''
