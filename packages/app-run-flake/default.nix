# app-run-flake — `nix run` equivalent for the apps-module sandbox.
#
# Builds a flake-ref package, optionally reads its
# `passthru.spacesAppManifest` for the *requested* permission set,
# merges with the operator's `--allow=...` flags, and execs the
# resulting target inside the same sandbox model that drives the
# static `services.spaces.apps.<name>` entries.
#
# Trust boundary: this is an operator CLI. Sandboxed apps (the agent
# included) do NOT have a path to this binary; the static-manifest +
# coordinator is the only way for non-operator callers to launch
# things.
{ pkgs, ... }:
let
  # Generator expression file — invoked via `nix build --file ...
  # --argstr ...` at runtime to produce the per-launch launcher. Kept
  # as a separate file because doing it inline as `--expr` would mean
  # escaping shell + nix quoting in lockstep, and the dependency on
  # ./../../lib/apps-launcher.nix is easier to express here.
  generator = ./generate-launcher.nix;
in
pkgs.writeShellApplication {
  name = "app-run-flake";

  runtimeInputs = [
    pkgs.nix
    pkgs.jq
    pkgs.coreutils
  ];

  text = ''
    set -euo pipefail

    usage() {
      cat <<EOF
    Usage: app-run-flake [OPTIONS] FLAKE_REF [-- TARGET_ARGS...]

    Builds the flake ref, generates a one-shot sandboxed launcher, and execs
    the target inside it.

    Options:
      --allow=PERMS         Comma-separated permission list (e.g. "wayland,network,dri").
                            Valid permissions: network, wayland, audio.playback,
                            audio.record, dri, fs.user-files, xwayland,
                            wm.foreign-toplevel-management, wm.spawn-named-tasks.
      --dbus-talk=NAME      Whitelist a DBus name this app may call. Repeatable.
                            Each occurrence adds one --talk filter to the bridge.
      --memory-high=SIZE    Override the 2G default MemoryHigh limit (e.g. "4G").
      --tasks-max=N         Override the 1024 default TasksMax limit.
      --app-id=ID           Override the auto-generated reverse-DNS app id
                            (default: spaces.app.flake.<flake-hash>).
      --yes / -y            Skip the confirmation prompt.

    Examples:
      app-run-flake --allow=wayland 'nixpkgs#hello'
      app-run-flake --allow=wayland,network --dbus-talk=org.freedesktop.Notifications \\
                    'nixpkgs#firefox' -- https://example.com
    EOF
    }

    FLAKE_REF=""
    ALLOW=""
    DBUS_TALK=()
    MEMORY_HIGH=""
    TASKS_MAX=""
    APP_ID_OVERRIDE=""
    YES=0
    TARGET_ARGS=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --allow=*)        ALLOW="''${1#--allow=}"; shift ;;
        --allow)          ALLOW="$2"; shift 2 ;;
        --dbus-talk=*)    DBUS_TALK+=("''${1#--dbus-talk=}"); shift ;;
        --dbus-talk)      DBUS_TALK+=("$2"); shift 2 ;;
        --memory-high=*)  MEMORY_HIGH="''${1#--memory-high=}"; shift ;;
        --memory-high)    MEMORY_HIGH="$2"; shift 2 ;;
        --tasks-max=*)    TASKS_MAX="''${1#--tasks-max=}"; shift ;;
        --tasks-max)      TASKS_MAX="$2"; shift 2 ;;
        --app-id=*)       APP_ID_OVERRIDE="''${1#--app-id=}"; shift ;;
        --app-id)         APP_ID_OVERRIDE="$2"; shift 2 ;;
        --yes|-y)         YES=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        --)               shift; TARGET_ARGS+=("$@"); break ;;
        -*)               echo "app-run-flake: unknown option $1" >&2; usage >&2; exit 2 ;;
        *)
          if [ -z "$FLAKE_REF" ]; then
            FLAKE_REF="$1"; shift
          else
            TARGET_ARGS+=("$1"); shift
          fi
          ;;
      esac
    done

    if [ -z "$FLAKE_REF" ]; then
      echo "app-run-flake: no flake ref given" >&2
      usage >&2
      exit 2
    fi

    # ── Build the package itself ──────────────────────────────────
    echo "app-run-flake: building $FLAKE_REF ..." >&2
    PACKAGE_PATH=$(nix build --no-link --print-out-paths "$FLAKE_REF")
    if [ -z "$PACKAGE_PATH" ]; then
      echo "app-run-flake: nix build returned no output path" >&2
      exit 1
    fi

    # ── Resolve the entry binary inside the package ──────────────
    # `lib.getExe` honours `meta.mainProgram`; falls back to the
    # package's pname.
    EXEC_PATH=$(nix eval --raw --apply '
      p: let lib = (import <nixpkgs> {}).lib; in lib.getExe p
    ' "$FLAKE_REF" 2>/dev/null || true)
    if [ -z "$EXEC_PATH" ] || [ ! -x "$EXEC_PATH" ]; then
      # Fallback: take the first executable in the bin/ dir.
      EXEC_PATH=$(find "$PACKAGE_PATH/bin" -maxdepth 1 -type f -executable 2>/dev/null | head -1 || true)
    fi
    if [ -z "$EXEC_PATH" ] || [ ! -x "$EXEC_PATH" ]; then
      echo "app-run-flake: couldn't resolve a runnable binary for $FLAKE_REF" >&2
      echo "  (tried lib.getExe + scanning $PACKAGE_PATH/bin)" >&2
      exit 1
    fi

    # ── Read passthru.spacesAppManifest if the package exposes it ─
    # Fully optional; if missing, we just emit `null`. Used today only
    # for the confirmation prompt; later versions of app-run-flake can
    # use it as the source of truth for what to ask consent for.
    PASSTHRU=$(nix eval --json --apply 'p: p.passthru.spacesAppManifest or null' "$FLAKE_REF" 2>/dev/null || echo "null")

    # ── Synthesise a stable per-flake app id (no override) ────────
    if [ -z "$APP_ID_OVERRIDE" ]; then
      FLAKE_HASH=$(printf '%s' "$FLAKE_REF" | sha256sum | cut -c1-12)
      APP_ID="spaces.app.flake.''${FLAKE_HASH}"
    else
      APP_ID="$APP_ID_OVERRIDE"
    fi

    # Per-run ephemeral state dir, relative to $HOME. The mkLauncher
    # `install -d` step + the `BindPaths=$HOME/$stateDir:/home/app`
    # property turn this into the sandbox's view of $HOME.
    STATE_DIR=".cache/spaces-app-flake/''${APP_ID}"

    # Confirmation prompt — operator sees exactly what's about to be
    # granted before any sandbox spins up.
    if [ "$YES" -ne 1 ]; then
      echo "" >&2
      echo "About to run: $FLAKE_REF" >&2
      echo "  app-id:       $APP_ID" >&2
      echo "  permissions:  ''${ALLOW:-(none)}" >&2
      if [ "''${#DBUS_TALK[@]}" -gt 0 ]; then
        echo "  dbus talk:    ''${DBUS_TALK[*]}" >&2
      fi
      if [ -n "$MEMORY_HIGH" ]; then echo "  memoryHigh:   $MEMORY_HIGH" >&2; fi
      if [ -n "$TASKS_MAX" ];   then echo "  tasksMax:     $TASKS_MAX" >&2; fi
      if [ "$PASSTHRU" != "null" ]; then
        echo "  (package declares its own passthru.spacesAppManifest:" >&2
        echo "$PASSTHRU" | jq . >&2
        echo "  )" >&2
      fi
      printf "Proceed? [y/N] " >&2
      read -r REPLY
      case "$REPLY" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "app-run-flake: aborted." >&2; exit 1 ;;
      esac
    fi

    # ── Generate the launcher derivation ──────────────────────────
    # Pass everything as --argstr; the generator decodes lists from
    # newline-joined strings.
    DBUS_TALK_ARG=""
    if [ "''${#DBUS_TALK[@]}" -gt 0 ]; then
      DBUS_TALK_ARG=$(printf '%s\n' "''${DBUS_TALK[@]}")
    fi

    LAUNCHER=$(nix build --no-link --print-out-paths \
      --file ${generator} \
      --argstr execPath "$EXEC_PATH" \
      --argstr appId "$APP_ID" \
      --argstr stateDir "$STATE_DIR" \
      --argstr allow "$ALLOW" \
      --argstr dbusTalk "$DBUS_TALK_ARG" \
      --argstr memoryHigh "''${MEMORY_HIGH:-}" \
      --argstr tasksMax "''${TASKS_MAX:-}" \
      --argstr spacesRepo ${./../..} \
    )

    # ── Exec the launcher with the user's target args ────────────
    BIN="$LAUNCHER/bin/app-run-flake-launch"
    if [ ! -x "$BIN" ]; then
      echo "app-run-flake: generator did not produce $BIN" >&2
      exit 1
    fi

    exec "$BIN" "''${TARGET_ARGS[@]}"
  '';
}
