# Per-app launcher generator.
#
# Pure function library extracted from `modules/nixos/apps.nix` so it
# can be consumed by two distinct callers:
#
#   1. The NixOS module — statically generates `app-run-<name>` for
#      every entry under `services.spaces.apps.<name>`. Schema is
#      validated through the module's option types.
#
#   2. A host-side dynamic CLI (`app-run-flake`) — calls `mkLauncher`
#      at runtime against an attrset assembled from CLI flags +
#      whatever `passthru.spacesAppManifest` the target package may
#      expose. No NixOS option-type validation; the caller is
#      responsible for shape.
#
# Both paths share the same sandbox baseline, dbus-bridge,
# wayland-app-context wrap, and security-context env vars, so the
# operator's "trust me, just run this" path is no weaker than the
# manifested path.
{
  pkgs,
  lib,
  coordinatorPkg, # ignored at the lib level today; kept in the
  # signature so the module can pass it for future
  # use (e.g. baking the coordinator path into
  # `wm.spawn-named-tasks`-aware error messages).
  waylandContextPkg,
}:
let
  sandboxEngine = "spaces.app-run";
  coordinatorSocketRel = "spaces-app-coordinator.sock";

  # In-sandbox helper that starts xdg-dbus-proxy on the session bus
  # the launcher bound at $DBUS_SESSION_BUS_ADDRESS, opens a filtered
  # socket in /tmp, re-points the env at the proxy socket, then execs
  # the rest of argv. Anything beyond the first `--` is the target.
  #
  # Args (zero or more, before `--`):
  #   --talk=NAME       allow method calls to NAME
  #   --own=NAME        allow owning NAME
  #   --see=NAME        allow seeing NAME in the registry
  #   --call=RULE       allow specific Sender.Method matches
  #   --broadcast=RULE  allow specific signals
  dbusBridge = pkgs.writeShellScript "app-dbus-bridge" ''
    set -eu

    proxy_args=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
      case "$1" in
        --talk=*|--own=*|--see=*|--call=*|--broadcast=*)
          proxy_args+=("$1")
          ;;
        *)
          echo "app-dbus-bridge: unknown arg: $1" >&2
          exit 2
          ;;
      esac
      shift
    done
    [ "''${1:-}" = "--" ] && shift

    if [ "$#" -eq 0 ]; then
      echo "app-dbus-bridge: no target after --" >&2
      exit 2
    fi

    if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      echo "app-dbus-bridge: DBUS_SESSION_BUS_ADDRESS not set" >&2
      exit 1
    fi

    proxy_sock="/tmp/dbus-proxy-$$.sock"

    # `--log` makes xdg-dbus-proxy write per-call audit lines to its
    # stderr (which becomes the systemd unit's journal). Format:
    #   *FILTERED* call destination=org.x.y member=Foo …
    #   *FILTERED-OUT* call destination=org.z.w member=Bar … (no policy)
    # Captured by tests; the future agent-log pipeline can scrape
    # these to build a forensic timeline of any sandbox's bus traffic.
    ${pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy \
      "$DBUS_SESSION_BUS_ADDRESS" "$proxy_sock" --filter --log \
      "''${proxy_args[@]}" &
    proxy_pid=$!

    i=0
    while [ $i -lt 20 ]; do
      [ -S "$proxy_sock" ] && break
      ${pkgs.coreutils}/bin/sleep 0.1
      i=$((i + 1))
    done
    if ! [ -S "$proxy_sock" ]; then
      echo "app-dbus-bridge: xdg-dbus-proxy never created $proxy_sock" >&2
      ${pkgs.coreutils}/bin/kill "$proxy_pid" 2>/dev/null || true
      exit 1
    fi

    export DBUS_SESSION_BUS_ADDRESS="unix:path=$proxy_sock"
    exec "$@"
  '';

  # Closed permission catalogue.
  knownPermissions = {
    network = "Network access. Without it, the sandbox runs with PrivateNetwork=true.";
    wayland = "Connect to the user's Wayland compositor. Almost always wanted.";
    "audio.playback" = "Pipewire/Pulse playback socket.";
    "audio.record" = "Pipewire mic capture. xdg-desktop-portal still mediates first use.";
    dri = "GPU access via /dev/dri/*. Required for hardware-accelerated rendering.";
    "fs.user-files" = "Read-only bind of ~/Documents, ~/Pictures, ~/Downloads.";
    xwayland = "Access the user's XWayland server. X11 clients can keylog each other.";
    "wm.spawn-named-tasks" = "Coordinator may launch other manifested apps on this app's behalf.";

    # Granular Wayland-protocol permissions. Niri gates each of
    # these on the per-permission patch in `patches/`. Until the
    # patch lands the names are declarative — they reach the
    # generated /etc/spaces/wayland-permissions.txt but the
    # compositor is still binary-gating on the security-context
    # restricted flag. (Apps that need a restricted protocol *now*
    # use `waylandSandbox = false` to skip the security-context
    # wrap entirely; that opt-out becomes obsolete when the patch
    # is applied.)
    "wayland.layer-shell" = "Bind zwlr_layer_shell_v1 (panels, bars, on-screen displays).";
    "wayland.session-lock" = "Bind ext_session_lock_manager_v1 (lock the screen).";
    "wayland.data-control" = "Bind wlr/ext data-control (read the user's clipboard).";
    "wayland.input-method" = "Bind zwp_input_method_manager_v2 (IME).";
    "wayland.virtual-keyboard" =
      "Bind zwp_virtual_keyboard_manager_v1 (synthetic keystrokes — voice-to-text typers, paste-as-typing).";
    "wayland.virtual-pointer" = "Bind zwlr_virtual_pointer_manager_v1 (synthetic pointer events).";
    "wayland.foreign-toplevel-management" =
      "Bind wlr/ext foreign-toplevel (enumerate, activate, close other apps' windows).";
    "wayland.ext-workspace" = "Bind ext_workspace_manager_v1.";
    "wayland.output-management" = "Bind zwlr_output_manager_v1 (configure displays).";
    "wayland.screen-capture" =
      "Bind zwlr_screencopy_manager_v1 (raw frame access — screenshot/screen-share tools).";
  };

  knownPermissionNames = lib.attrNames knownPermissions;

  effectiveOf = app: lib.subtractLists app.permissions.denied app.permissions.granted;

  # Default values for every field `mkLauncher` consults. The NixOS
  # module wraps this with proper option types (and validates against
  # the known-permissions enum); dynamic callers use `withDefaults`
  # directly so missing keys get sensible values.
  defaultsFor = name: {
    exec = null;
    args = [ ];
    permissions = {
      granted = [ ];
      requested = [ ];
      denied = [ ];
    };
    stateDir = ".local/share/spaces/apps/${name}";
    appId = "spaces.app.${name}";
    allowedArgs = [ ];
    dbusSession = {
      talk = [ ];
      own = [ ];
      see = [ ];
      call = [ ];
      broadcast = [ ];
    };
    resources = {
      memoryHigh = "2G";
      tasksMax = 1024;
    };
    # When `wayland` is granted, also wrap the target in
    # wayland-app-context so the compositor gates restricted
    # protocol globals (screencopy, foreign-toplevel, layer-shell,
    # data-control, virtual-keyboard, ...) via security-context-v1.
    #
    # Set to `false` for apps that legitimately need one of the
    # restricted protocols (input methods, voice-to-text typers,
    # screen-share tools, wlr-bars). The Wayland socket is still
    # bound — only the security-context wrap is skipped. This is a
    # real isolation trade-off: the app gets full registry access.
    # Per-permission Niri gating (the Tier-2 hardening item) will
    # eventually obsolete this knob.
    waylandSandbox = true;
    # Extra host paths to make visible inside the sandbox, on top of
    # what the permission set already binds. Each entry is
    # `{ source; target ? source; mode ? "ro"; }`. `source` may use
    # `${VAR}` for shell expansion (the launcher exports
    # XDG_RUNTIME_DIR / HOME before invoking systemd-run).
    extraBinds = [ ];
    # Per-app credentials staged via systemd `LoadCredential=`. Each
    # `name = host-path` pair tells systemd to read the host file
    # at unit-setup time and expose its content inside the sandbox
    # at $CREDENTIALS_DIRECTORY/<name>, mode 0400, only readable by
    # the unit. Works *with* the InaccessiblePaths masking: systemd
    # reads the source under PID 1 / the user manager (which sees
    # the unmasked filesystem), so the sandboxed app never has to
    # be granted direct access to the host path.
    credentials = { };
  };

  # Apply defaults to a partial app entry. Deep-merges via
  # recursiveUpdate so callers can override a single nested key
  # (e.g. just `permissions.granted = [...]`) without losing the
  # other nested defaults.
  withDefaults = name: app: lib.recursiveUpdate (defaultsFor name) app;

  # The core launcher generator. Takes a fully-defaulted app entry
  # (use `withDefaults` if any field may be missing) and emits a
  # `writeShellScriptBin` derivation named `app-run-<name>` whose
  # bin/ script is the host-side launcher.
  #
  # Two-tier permission resolution at launch time:
  #   1. STATIC: `permissions.granted` / `permissions.denied` baked
  #      at Nix-eval time. Always in effect.
  #   2. RUNTIME: $HOME/.local/state/spaces/grants/<appId>.json,
  #      written by `spaces-apps grant`. Read at every launch;
  #      UNION'd with static granted, then static denied is
  #      subtracted last (so a denied permission can never be
  #      runtime-granted around the operator's hard deny).
  #
  # Permission-dependent property flags are emitted from bash at
  # runtime rather than Nix-eval time so runtime grants engage.
  # Static configuration (baseline sandbox, dbus bridge filter
  # rules, credentials, extraBinds) stays baked since changing
  # those requires a rebuild anyway.
  mkLauncher =
    name: rawApp:
    let
      app = withDefaults name rawApp;
      execPath = if app.exec != null then app.exec else lib.getExe app.package;

      baseProps = [
        # ── Filesystem isolation ───────────────────────────────────
        "--property=PrivateTmp=true"
        "--property=ProtectHome=tmpfs"
        # `full` (not `strict`) so the sandbox can write to /run/user
        # — the security-context helper needs to bind a new Unix
        # socket there for the sandboxed Wayland connection, and most
        # GUI apps cache state under $XDG_RUNTIME_DIR. /etc, /usr,
        # /boot remain read-only.
        "--property=ProtectSystem=full"

        # ── Kernel-surface isolation ───────────────────────────────
        "--property=ProtectKernelTunables=true"
        "--property=ProtectKernelModules=true"
        "--property=ProtectKernelLogs=true"
        "--property=ProtectControlGroups=true"
        "--property=ProtectClock=true"
        "--property=ProtectHostname=true"

        # Both ProcSubset=pid and ProtectProc=invisible are *inert
        # in `systemd-run --user` mode* — they require CAP_SYS_ADMIN
        # to remount /proc with the subset=/hidepid= options, which
        # the user manager doesn't have. Kept here so the launcher
        # stays a single source of truth: a future migration to
        # system-services-per-app picks them up automatically.
        "--property=ProcSubset=pid"
        "--property=ProtectProc=invisible"

        # ── Privilege drop ─────────────────────────────────────────
        "--property=NoNewPrivileges=true"
        "--property=RestrictSUIDSGID=true"
        "--property=CapabilityBoundingSet="
        "--property=AmbientCapabilities="

        # ── Process / kernel-API hardening ─────────────────────────
        "--property=LockPersonality=true"
        "--property=RestrictNamespaces=true"
        "--property=RestrictRealtime=true"

        # System-call allow-list.
        "--property=SystemCallFilter=@system-service"
        "--property=SystemCallFilter=~@privileged @resources @swap @reboot @module @mount @raw-io @cpu-emulation @obsolete @debug"
        "--property=SystemCallErrorNumber=EPERM"
        "--property=SystemCallArchitectures=native"

        # Address-family allow-list.
        "--property=RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK"

        # ── Kernel keyring + filesystem defaults ───────────────────
        "--property=KeyringMode=private"
        "--property=UMask=0077"

        # ── Operator-secret-store masking ──────────────────────────
        # Block sandboxed apps from groveling through the host-side
        # secret stores. These dirs typically live at mode 0750
        # root:users (or similar), so a sandboxed app running as the
        # user could otherwise read every staged credential.
        # InaccessiblePaths over-mounts each path with an empty
        # directory or device node — reads return EACCES.
        #
        # Leading `-` makes systemd skip the entry when the host
        # path is missing (most systems won't have all three).
        # Multiple paths are space-separated within one directive.
        #
        # Apps that legitimately need a specific credential should
        # use systemd's LoadCredential= (per-unit private path at
        # $CREDENTIALS_DIRECTORY/<name>) or talk to the user keyring
        # via `dbusSession.talk = [ "org.freedesktop.secrets" ]`.
        "--property=InaccessiblePaths=-/run/secrets -/run/agenix.d -/run/spaces-secrets"

        # ── Resource limits ────────────────────────────────────────
        "--property=MemoryHigh=${app.resources.memoryHigh}"
        "--property=TasksMax=${toString app.resources.tasksMax}"

        # ── Per-app $HOME ──────────────────────────────────────────
        "--setenv=HOME=/home/app"
        "--setenv=XDG_DATA_HOME=/home/app/.local/share"
        "--setenv=XDG_CONFIG_HOME=/home/app/.config"
        "--setenv=XDG_CACHE_HOME=/home/app/.cache"
        "--setenv=XDG_STATE_HOME=/home/app/.local/state"

        # ── security-context-v1 identity ───────────────────────────
        "--setenv=XDG_SECURITY_CONTEXT_APP_ID=${app.appId}"
        "--setenv=XDG_SECURITY_CONTEXT_SANDBOX_ENGINE=${sandboxEngine}"
      ];

      # dbus props are based on dbusSession config (Nix-eval-time) not
      # on the runtime permission set, so they stay baked.
      dbusEnabled =
        app.dbusSession.talk != [ ]
        || app.dbusSession.own != [ ]
        || app.dbusSession.see != [ ]
        || app.dbusSession.call != [ ]
        || app.dbusSession.broadcast != [ ];

      dbusProps =
        if dbusEnabled then
          [
            "--property=BindReadOnlyPaths=-\${XDG_RUNTIME_DIR}/bus"
            "--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus"
          ]
        else
          [ "--property=UnsetEnvironment=DBUS_SESSION_BUS_ADDRESS" ];

      credentialProps = lib.mapAttrsToList (
        name: path: "--property=LoadCredential=${name}:${path}"
      ) app.credentials;

      # extraBinds: operator-declared additional mounts. Useful for
      # cross-sandbox IPC (e.g. a daemon's runtime dir that the host
      # CLI needs to reach) or for exposing one specific config file
      # that doesn't fit the existing permission shapes.
      extraBindProps = map (
        b:
        let
          src = b.source;
          dst = if b.target or null != null then b.target else src;
          op = if (b.mode or "ro") == "rw" then "BindPaths" else "BindReadOnlyPaths";
          # Leading `-` makes systemd skip the entry when the host
          # source is missing — useful for sockets whose publisher
          # may not be running yet.
          dash = if b.optional or false then "-" else "";
        in
        "--property=${op}=${dash}${src}:${dst}"
      ) app.extraBinds;

      # spawnProps removed — moved to a runtime bash conditional
      # since `wm.spawn-named-tasks` can now be granted at runtime.

      stateBindProp = "--property=BindPaths=\${HOME}/${app.stateDir}:/home/app";

      # Static props that don't depend on the permission set —
      # baked at Nix-eval time. Runtime grants only change the
      # *permission-dependent* props (see the bash conditionals
      # below).
      staticProps = [
        stateBindProp
      ]
      ++ baseProps
      ++ dbusProps
      ++ extraBindProps
      ++ credentialProps;

      # Pre-baked spawn props are dropped — moved to a bash
      # conditional below since wm.spawn-named-tasks can be granted
      # at runtime. (Same for fs.user-files, audio.*, wayland,
      # xwayland, network, dri.)

      staticPropsBody = lib.concatMapStringsSep "\n  " (p: ''"${p}"'') staticProps;

      # Pre-baked static permission lists for the bash array
      # population. Use lib.escapeShellArg to be defensive even
      # though permission names are validated via enum types.
      staticGrantedShell = lib.concatStringsSep " " (map lib.escapeShellArg app.permissions.granted);
      staticDeniedShell = lib.concatStringsSep " " (map lib.escapeShellArg app.permissions.denied);
    in
    pkgs.writeShellScriptBin "app-run-${name}" ''
      set -eu

      : "''${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
      export XDG_RUNTIME_DIR

      if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
        for sock in "$XDG_RUNTIME_DIR"/wayland-?; do
          [ -S "$sock" ] || continue
          WAYLAND_DISPLAY=$(basename "$sock")
          break
        done
      fi
      export WAYLAND_DISPLAY

      install -d -m 0700 "''${HOME}/${app.stateDir}"

      # ── Effective permission resolution ─────────────────────
      # STATIC grants (baked) ∪ RUNTIME grants (from grants file)
      # minus STATIC denies. Denies applied LAST so the operator's
      # hard deny can never be bypassed by `spaces-apps grant`.
      declare -A EFFECTIVE_PERMS
      for p in ${staticGrantedShell}; do
        EFFECTIVE_PERMS["$p"]=1
      done
      grants_file="''${HOME}/.local/state/spaces/grants/${app.appId}.json"
      if [ -r "$grants_file" ]; then
        while IFS= read -r p; do
          [ -n "$p" ] && EFFECTIVE_PERMS["$p"]=1
        done < <(${pkgs.jq}/bin/jq -r '.granted[]?' "$grants_file" 2>/dev/null || true)
      fi
      for p in ${staticDeniedShell}; do
        unset "EFFECTIVE_PERMS[$p]"
      done

      has_perm() { [ -n "''${EFFECTIVE_PERMS[$1]+x}" ]; }

      # Audit-line effective list (sorted for stability).
      eff_list=""
      for p in $(printf '%s\n' "''${!EFFECTIVE_PERMS[@]}" | sort); do
        if [ -n "$eff_list" ]; then eff_list+=","; fi
        eff_list+="$p"
      done

      printf '{"event":"app-run","app":"${name}","appId":"${app.appId}","granted":%s,"denied":%s,"effective":"%s"}\n' \
        '${builtins.toJSON app.permissions.granted}' \
        '${builtins.toJSON app.permissions.denied}' \
        "$eff_list" >&2

      # ── Build property argv ──────────────────────────────────
      args=(
        ${staticPropsBody}
      )

      # Permission-dependent flags — at runtime so grants engage.
      if ! has_perm network; then
        args+=("--property=PrivateNetwork=true")
      fi

      if has_perm dri; then
        args+=("--property=DeviceAllow=char-drm")
      else
        args+=("--property=PrivateDevices=true")
      fi

      if has_perm "audio.playback" || has_perm "audio.record"; then
        args+=("--property=BindReadOnlyPaths=-''${XDG_RUNTIME_DIR}/pipewire-0")
        args+=("--property=BindReadOnlyPaths=-''${XDG_RUNTIME_DIR}/pulse")
      fi

      if has_perm wayland; then
        args+=("--property=BindReadOnlyPaths=''${XDG_RUNTIME_DIR}/''${WAYLAND_DISPLAY:-wayland-0}")
        args+=("--setenv=WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-wayland-0}")
      else
        args+=("--property=UnsetEnvironment=WAYLAND_DISPLAY")
      fi

      if has_perm xwayland; then
        args+=("--property=BindReadOnlyPaths=-/tmp/.X11-unix")
        args+=("--setenv=DISPLAY=''${DISPLAY:-:0}")
      else
        args+=("--property=UnsetEnvironment=DISPLAY")
      fi

      if has_perm "fs.user-files"; then
        args+=("--property=BindReadOnlyPaths=-''${HOME}/Documents:/home/app/Documents")
        args+=("--property=BindReadOnlyPaths=-''${HOME}/Pictures:/home/app/Pictures")
        args+=("--property=BindReadOnlyPaths=-''${HOME}/Downloads:/home/app/Downloads")
      fi

      if has_perm "wm.spawn-named-tasks"; then
        args+=("--property=BindPaths=''${XDG_RUNTIME_DIR}/${coordinatorSocketRel}")
        args+=("--setenv=APP_COORDINATOR_SOCKET=''${XDG_RUNTIME_DIR}/${coordinatorSocketRel}")
      fi

      # ── Build target argv chain (wrappers + binary) ──────────
      target=(${execPath} ${lib.escapeShellArgs app.args})

      # wayland-app-context wrap — depends on RUNTIME wayland
      # permission AND the static waylandSandbox knob.
      if has_perm wayland && [ "${if app.waylandSandbox then "1" else "0"}" = "1" ]; then
        target=(
          "${waylandContextPkg}/bin/wayland-app-context"
          "--engine=${sandboxEngine}"
          "--app-id=${app.appId}"
          "--instance-id=app-${name}-$$"
          "--"
          "''${target[@]}"
        )
      fi

      # dbus bridge wrap — STATIC (gated on dbusSession non-empty).
      ${lib.optionalString dbusEnabled ''
        target=(
          "${dbusBridge}"
          ${lib.concatMapStringsSep "\n          " (n: ''"--talk=${n}"'') app.dbusSession.talk}
          ${lib.concatMapStringsSep "\n          " (n: ''"--own=${n}"'') app.dbusSession.own}
          ${lib.concatMapStringsSep "\n          " (n: ''"--see=${n}"'') app.dbusSession.see}
          ${lib.concatMapStringsSep "\n          " (n: ''"--call=${n}"'') app.dbusSession.call}
          ${lib.concatMapStringsSep "\n          " (n: ''"--broadcast=${n}"'') app.dbusSession.broadcast}
          "--"
          "''${target[@]}"
        )
      ''}

      exec ${pkgs.systemd}/bin/systemd-run --user --no-block --collect \
        --unit="app-${name}-$$" \
        --description="spaces app: ${name}" \
        "''${args[@]}" \
        -- "''${target[@]}" "$@"
    '';
in
{
  inherit
    mkLauncher
    knownPermissions
    knownPermissionNames
    effectiveOf
    withDefaults
    sandboxEngine
    coordinatorSocketRel
    dbusBridge
    ;
}
