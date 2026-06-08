# Cheap nix-eval contract for the noctalia agent-session indicator —
# the bundled `spaces-sessions` plugin shipped in the top-middle bar.
#
# What a plain system build does NOT catch but the user-visible feature
# depends on:
#   - the plugin is enabled BY DEFAULT, sits in the center section
#     alongside the workspace pills, and is wired to the pi-chat IPC
#     focus command (wrong values build fine yet ship a dead / missing
#     indicator);
#   - its QML actually lands under ~/.config/noctalia/plugins/spaces-
#     sessions/ (without the materialise step noctalia would have a
#     dangling registry entry pointing at nothing);
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
      { networking.hostName = "noctalia-sessions"; }
    ];
  };

  # The bar's ExecStartPre — the per-user config seed/merge/materialise.
  # Inheriting it into the runCommand env below also builds it
  # (shellcheck) as a dep.
  mergeScript = spacesSystem.config.systemd.user.services.noctalia-shell.serviceConfig.ExecStartPre;
in
pkgs.runCommand "spaces-noctalia-session-indicator-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit mergeScript;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # Stage a long-running host: plugins.json carries a user plugin and
    # an explicit spaces-sessions=false (the user previously disabled
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
        "spaces-sessions": { "enabled": false }
      }
    }
    EOF
    cat >"$cfg/settings.json" <<'EOF'
    { "bar": { "position": "bottom" }, "userKey": 42 }
    EOF

    "$mergeScript"

    # ── 1. plugin enable state ──────────────────────────────────────
    jq -e '.states["spaces-sessions"].enabled == true' "$cfg/plugins.json" >/dev/null \
      || fail "merge did not enable spaces-sessions over a user-disabled entry"
    jq -e '.states["user-weather"].enabled == true' "$cfg/plugins.json" >/dev/null \
      || fail "merge dropped the user's own marketplace plugin entry"

    # ── 2. bar widget placement ─────────────────────────────────────
    jq -e '.bar.widgets.center | map(.id) | (index("Workspace") != null) and (index("plugin:spaces-sessions") != null)' \
      "$cfg/settings.json" >/dev/null \
      || fail "center bar must carry Workspace + plugin:spaces-sessions"
    jq -e '.bar.position == "top"' "$cfg/settings.json" >/dev/null \
      || fail "managed bar.position lost in the merge"
    jq -e '.userKey == 42' "$cfg/settings.json" >/dev/null \
      || fail "merge clobbered an unmanaged user setting"

    # ── 3. plugin settings.json (focusCommand) ──────────────────────
    jq -e '.focusCommand | test("quickshell ipc -c pi-chat call pi-chat")' \
      "$cfg/plugins/spaces-sessions/settings.json" >/dev/null \
      || fail "plugin settings.json focusCommand must target the pi-chat IPC"

    # ── 4. plugin code materialised under plugins/spaces-sessions/ ──
    # Per-file symlinks into the store; the directory itself must be a
    # real dir so noctalia can write settings.json next to them and the
    # stale-plugin purge (which sweeps top-level symlinks in plugins/)
    # leaves us alone.
    [ -d "$cfg/plugins/spaces-sessions" ] && [ ! -L "$cfg/plugins/spaces-sessions" ] \
      || fail "plugins/spaces-sessions must be a real directory (not a symlink)"
    for f in manifest.json Main.qml BarWidget.qml; do
      [ -L "$cfg/plugins/spaces-sessions/$f" ] \
        || fail "plugins/spaces-sessions/$f must be materialised as a symlink"
      [ -e "$cfg/plugins/spaces-sessions/$f" ] \
        || fail "plugins/spaces-sessions/$f symlink resolves to nothing"
    done

    touch "$out"
  ''
