# Cheap nix-eval contract for the noctalia voice indicator — the bundled
# `voice-indicator` plugin shipped in the top-middle bar.
#
# What a plain system build does NOT catch but the user-visible feature
# depends on:
#   - the plugin is enabled BY DEFAULT, sits in the center section
#     alongside the workspace pills + session indicator, and is wired to
#     the absolute spaces-voice-record-toggle wrapper (wrong values build
#     fine yet ship a dead / missing indicator);
#   - its QML and i18n actually land under ~/.config/noctalia/plugins/
#     voice-indicator/ (without the materialise step noctalia would have a
#     dangling registry entry pointing at nothing, and tr() would have no
#     i18n/en.json to read);
#   - those declarative defaults survive the deep merge against a
#     pre-existing user config: the enable flag must win over a
#     user-disabled entry while the user's own plugins / settings keys
#     are preserved.
#
# Exercises the module's REAL ExecStartPre against a staged $HOME,
# mirroring how the sibling purge / merge tests run their real binaries.
# ~1s, no VM.
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

  spacesSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = baseModules ++ [
      inputs.self.nixosModules.spaces
      { networking.hostName = "noctalia-voice-indicator"; }
    ];
  };

  # The bar's ExecStartPre — the per-user config seed/merge/materialise.
  # Inheriting it into the runCommand env below also builds it
  # (shellcheck) as a dep.
  mergeScript = spacesSystem.config.systemd.user.services.noctalia-shell.serviceConfig.ExecStartPre;
in
pkgs.runCommand "spaces-voice-indicator-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit mergeScript;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # Stage a long-running host: plugins.json carries a user plugin and
    # an explicit voice-indicator=false (the user previously disabled
    # ours); settings.json has a non-top bar position plus an unmanaged
    # user key. The merge must enable ours, place us in center, and
    # leave the user's stuff alone.
    export HOME=$(mktemp -d)
    cfg="$HOME/.config/noctalia"
    mkdir -p "$cfg/plugins"
    cat >"$cfg/plugins.json" <<'EOF'
    {
      "version": 2,
      "states": {
        "user-weather": { "enabled": true },
        "voice-indicator": { "enabled": false }
      }
    }
    EOF
    cat >"$cfg/settings.json" <<'EOF'
    { "bar": { "position": "bottom" }, "userKey": 42 }
    EOF

    "$mergeScript"

    # ── 1. plugin enable state ──────────────────────────────────────
    jq -e '.states["voice-indicator"].enabled == true' "$cfg/plugins.json" >/dev/null \
      || fail "merge did not enable voice-indicator over a user-disabled entry"
    jq -e '.states["user-weather"].enabled == true' "$cfg/plugins.json" >/dev/null \
      || fail "merge dropped the user's own marketplace plugin entry"

    # ── 2. bar widget placement ─────────────────────────────────────
    jq -e '.bar.widgets.center | map(.id) | (index("Workspace") != null) and (index("plugin:spaces-sessions") != null) and (index("plugin:voice-indicator") != null)' \
      "$cfg/settings.json" >/dev/null \
      || fail "center bar must carry Workspace + plugin:spaces-sessions + plugin:voice-indicator"
    jq -e '.bar.position == "top"' "$cfg/settings.json" >/dev/null \
      || fail "managed bar.position lost in the merge"
    jq -e '.userKey == 42' "$cfg/settings.json" >/dev/null \
      || fail "merge clobbered an unmanaged user setting"

    # ── 3. plugin settings.json (toggleCommand + bar pulse) ─────────
    jq -e '.toggleCommand | test("spaces-voice-record-toggle")' \
      "$cfg/plugins/voice-indicator/settings.json" >/dev/null \
      || fail "plugin settings.json toggleCommand must target spaces-voice-record-toggle"
    # The whole-bar ambient "recording" pulse ships ON by default; the
    # managed settings must carry barPulse=true so the cue is wired
    # without per-host opt-in.
    jq -e '.barPulse == true' \
      "$cfg/plugins/voice-indicator/settings.json" >/dev/null \
      || fail "plugin settings.json must default barPulse=true"

    # ── 4. plugin code materialised under plugins/voice-indicator/ ──
    # Per-file symlinks into the store; the directory itself must be a
    # real dir so noctalia can write settings.json next to them and the
    # stale-plugin purge (which sweeps top-level symlinks in plugins/)
    # leaves us alone. i18n/ is a top-level entry, so it materialises as
    # a (resolving) symlink through which tr() reads i18n/<lang>.json.
    [ -d "$cfg/plugins/voice-indicator" ] && [ ! -L "$cfg/plugins/voice-indicator" ] \
      || fail "plugins/voice-indicator must be a real directory (not a symlink)"
    for f in manifest.json Main.qml BarWidget.qml; do
      [ -L "$cfg/plugins/voice-indicator/$f" ] \
        || fail "plugins/voice-indicator/$f must be materialised as a symlink"
      [ -e "$cfg/plugins/voice-indicator/$f" ] \
        || fail "plugins/voice-indicator/$f symlink resolves to nothing"
    done
    [ -e "$cfg/plugins/voice-indicator/i18n/en.json" ] \
      || fail "plugins/voice-indicator/i18n/en.json must resolve for tr() to localise"

    touch "$out"
  ''
