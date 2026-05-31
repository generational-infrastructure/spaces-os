# Apps NixOS module.
#
# Declarative, manifest-driven application sandbox layer modelled
# on Android's permission system. Each "app" is a named submodule
# under `services.spaces.apps.<name>` declaring its package, the
# permissions it has been granted, the ones it has requested (for
# documentation + the future permission-store UI), the ones the
# operator has hard-denied, and a private state directory that
# becomes `$HOME` inside the sandbox.
#
# The module generates a launcher binary `app-run-<name>` on the
# system PATH that spawns the app under `systemd-run --user --scope`
# with sandbox properties derived from the permission set:
#   - default deny: no $HOME, no network, no devices, no /tmp
#   - per-permission grants open one capability at a time
# It also tags the sandbox with a security-context-v1 app-id and
# instance-id so a future Niri policy patch can gate Wayland
# protocol globals (wlr-screencopy, foreign-toplevel-management,
# etc.) on app identity.
#
# Out of scope for v1, intentionally:
#   - permission grant store (will reuse xdg-desktop-portal-
#     permission-store; consults `appId`)
#   - per-method DBus arg-filter rules (today: --talk/--own/--see/
#     --call/--broadcast suffice; an OAuth-scope-style policy DSL
#     can layer on top later if needed)
#   - compositor-side enforcement of wm.* permissions (separate
#     Niri patch consumes `appId` + the granted set)
#   - settings UI (will read the same manifest + the grant store)
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.spaces.apps;

  coordinatorPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.app-coordinator;
  waylandContextPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.wayland-app-context;
  spacesAppsCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.spaces-apps;

  coordinatorManifestPath = "/etc/spaces/app-coordinator/manifest.json";

  # All the launcher-construction logic + closed permission catalogue
  # lives in ../../lib/apps-launcher.nix so the same code path is
  # consumed by both this NixOS module (static, schema-validated) and
  # the host-side `app-run-flake` CLI (dynamic, runtime-constructed).
  launcherLib = import ../../lib/apps-launcher.nix {
    inherit
      pkgs
      lib
      coordinatorPkg
      waylandContextPkg
      ;
  };

  inherit (launcherLib) mkLauncher knownPermissionNames effectiveOf;

  # Re-bound here because the systemd user-service config below needs
  # the socket path; not exposed through the lib's interface to avoid
  # leaking implementation details unnecessarily.

  appSubmodule = lib.types.submodule (
    { name, ... }:
    {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          description = "Package containing the app's entry binary.";
        };

        exec = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Absolute path to the binary inside `package`. When null
            (the default), the launcher resolves it via `lib.getExe
            package` (which honours `meta.mainProgram`).
          '';
        };

        args = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Static arguments prepended to the launcher's argv.";
        };

        permissions = {
          granted = lib.mkOption {
            type = lib.types.listOf (lib.types.enum knownPermissionNames);
            default = [ ];
            description = ''
              Permissions effective at launch with no prompt. The
              launcher derives sandbox properties from this set.
            '';
          };

          requested = lib.mkOption {
            type = lib.types.listOf (lib.types.enum knownPermissionNames);
            default = [ ];
            description = ''
              Permissions the app would like to use but that the
              operator has not granted. Surfaced in the future
              permission-store UI for runtime consent. The launcher
              does NOT consult this list.
            '';
          };

          denied = lib.mkOption {
            type = lib.types.listOf (lib.types.enum knownPermissionNames);
            default = [ ];
            description = ''
              Hard deny. Subtracted from `granted` before the launcher
              computes sandbox properties — use for permissions the
              operator knows are incompatible with the app's role.
            '';
          };
        };

        stateDir = lib.mkOption {
          type = lib.types.str;
          default = ".local/share/spaces/apps/${name}";
          description = ''
            App-private data directory, relative to the launching
            user's `$HOME`. Bind-mounted at `/home/app` inside the
            sandbox so the app's view of `$HOME` is empty except for
            its own state. Created on first launch (mode 0700) by
            the launcher itself; no system-wide tmpfiles entry.
          '';
        };

        appId = lib.mkOption {
          type = lib.types.str;
          default = "spaces.app.${name}";
          description = ''
            Reverse-DNS identifier. Exported as
            $XDG_SECURITY_CONTEXT_APP_ID and passed to the
            compositor's security-context-v1 handshake; will key
            the future permission store.
          '';
        };

        allowedArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Regex patterns (Go RE2 syntax) that *runtime* args
            supplied by coordinator callers must match. Empty (the
            default) rejects any runtime arg — argv passthrough is
            opt-in per app.

            Each runtime arg is accepted if at least one pattern
            matches. The coordinator anchors every pattern to a full
            string match (`\A…\z`), so a pattern can never accept an
            arg that merely contains it as a substring. Patterns are
            still required to carry explicit `^`/`$` (see the assertion
            below) so manifest intent reads unambiguously. Static
            `args` baked at module-eval time are not subject to this
            check (they are operator-controlled).
          '';
          example = lib.literalExpression ''
            [
              "^https?://.+$"            # URLs for a browser
              "^--profile=[a-zA-Z0-9-]+$" # specific profile flag
            ]
          '';
        };

        resources = {
          memoryHigh = lib.mkOption {
            type = lib.types.str;
            default = "2G";
            description = ''
              `MemoryHigh=` property — soft memory limit. systemd
              throttles allocation above this; the kernel only OOMs
              the unit at a separate (currently unset) `MemoryMax`.
              2G covers most user-facing apps without surprising
              browsers / Electron apps.
            '';
          };
          tasksMax = lib.mkOption {
            type = lib.types.int;
            default = 1024;
            description = ''
              `TasksMax=` property — fork-bomb defense. Caps the
              total number of processes + threads inside the unit.
              1024 covers most user apps including small browsers;
              modern Electron / Chromium needs more, raise per-app.
            '';
          };
        };

        dbusSession = {
          talk = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Well-known DBus session-bus names this app may make
              method calls to. Wildcards (`*`) are supported by
              xdg-dbus-proxy (e.g. `org.freedesktop.portal.*`).

              Any non-empty entry in `talk` / `own` / `see` / `call`
              / `broadcast` activates the per-app xdg-dbus-proxy
              filter: the sandboxed target receives
              `DBUS_SESSION_BUS_ADDRESS` pointing at the filtered
              socket, NOT the user's real session bus. An app with
              all five lists empty has no session-bus access at all.
            '';
            example = lib.literalExpression ''
              [ "org.freedesktop.Notifications" "org.freedesktop.portal.*" ]
            '';
          };
          own = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Well-known names this app may register/own on the session bus.";
          };
          see = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Names this app may merely *see* (NameOwnerChanged signals, registry entries) without being allowed to call.";
          };
          call = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Specific `Sender.Method` matches passed verbatim to xdg-dbus-proxy --call. Use to allow narrow method subsets.";
          };
          broadcast = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Specific signal matches passed verbatim to xdg-dbus-proxy --broadcast.";
          };
        };

        waylandSandbox = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            When `wayland` is granted, additionally wrap the target in
            `wayland-app-context` so the compositor gates restricted
            protocol globals (wlr-screencopy, foreign-toplevel,
            data-control, virtual-keyboard, layer-shell, …) via
            security-context-v1.

            Set to `false` only for apps that legitimately need one
            of the restricted protocols and where the operator
            accepts that the app sees the full Wayland registry.
            Voice-to-text typers and input methods are the canonical
            use case. Future per-permission Niri gating will
            obsolete this opt-out.
          '';
        };

        spawnableBy = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "*" ];
          description = ''
            Caller app-ids allowed to spawn this app through the
            coordinator. The coordinator resolves the caller via
            SO_PEERCRED + `/proc/<pid>/cgroup`:

              - peer running inside `app-<name>-<pid>.service` →
                `spaces.app.<name>`
              - any other peer (operator shell, niri keybind helper,
                a transient one-shot script) → `host`

            `"*"` accepts any caller (the default; preserves the
            pre-peer-auth behaviour). `"host"` accepts only
            unsandboxed callers. Otherwise list specific app-ids,
            e.g. `[ "spaces.app.agent" ]` for an app that only the
            agent should be able to launch.
          '';
          example = lib.literalExpression ''
            [ "spaces.app.agent" "host" ]
          '';
        };

        credentials = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = ''
            Per-app credentials staged via systemd `LoadCredential=`.
            Each `<name> = <host-path>` pair tells systemd to read the
            host file at unit-setup time and expose its content inside
            the sandbox at `$CREDENTIALS_DIRECTORY/<name>`, mode 0400,
            only readable by the unit. Works alongside the
            `InaccessiblePaths=` baseline — the credential is staged
            without ever needing to grant the sandbox direct
            filesystem access to the host secret store.

            Source paths must be readable by the user manager (alice).
            Typical pattern: a root-owned activation service stages
            the secret at `/run/spaces-secrets/<name>` (mode 0640
            root:users) and the app's `credentials` declaration loads
            from there — the masking baseline blocks every *other*
            app from reading the path, this declaration is the
            one-app-at-a-time opt-in.

            For secrets that live in the user keyring, prefer
            `dbusSession.talk = [ "org.freedesktop.secrets" ]` instead
            so the keyring stays the source of truth.
          '';
          example = lib.literalExpression ''
            {
              openrouter = "/run/spaces-secrets/openrouter-api-key";
            }
          '';
        };

        extraBinds = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                source = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Host-side path to bind into the sandbox. May contain
                    shell variables (`$HOME`, `$XDG_RUNTIME_DIR`) that
                    the launcher script expands at run time.
                  '';
                };
                target = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "In-sandbox path. When null, reuse `source`.";
                };
                mode = lib.mkOption {
                  type = lib.types.enum [
                    "ro"
                    "rw"
                  ];
                  default = "ro";
                  description = "`ro` → BindReadOnlyPaths=; `rw` → BindPaths=.";
                };
                optional = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = ''
                    Prefix the entry with `-` so systemd skips it
                    when the host source is missing. Use for sockets
                    whose publisher may legitimately be down.
                  '';
                };
              };
            }
          );
          default = [ ];
          description = ''
            Additional bind-mounts on top of what the permission set
            already provides. Use for cross-sandbox IPC (daemon's
            runtime directory that the host CLI must reach), or for
            exposing a single config file that doesn't match any of
            the coarse permission shapes.
          '';
        };
      };
    }
  );

  launchers = lib.mapAttrs mkLauncher cfg;

  # An app's launcher absolute path is the manifest's source of truth
  # for "what binary does the coordinator exec when asked to spawn this?"
  launcherPathOf = name: launcher: "${launcher}/bin/app-run-${name}";

  manifestData = {
    apps = lib.mapAttrs (name: launcher: {
      launcherPath = launcherPathOf name launcher;
      inherit (cfg.${name}) allowedArgs spawnableBy appId;
      inherit (cfg.${name}.permissions) granted requested denied;
    }) launchers;
  };

  manifestFile = (pkgs.formats.json { }).generate "app-coordinator-manifest.json" manifestData;

  # Permission catalogue exposed as a static at-rest file. CLI tools
  # (and a future grant UI) read this to render human-readable
  # descriptions next to each permission name. The catalogue itself
  # lives in lib/apps-launcher.nix; this just publishes the
  # `knownPermissions` attrset as JSON.
  permissionsFile =
    (pkgs.formats.json { }).generate "spaces-permissions.json"
      launcherLib.knownPermissions;

  # Wayland-permissions map consumed by patched niri (when the
  # `patches/niri-per-permission-gating.patch.draft` lands). Lines
  # are `<appId> <permission>` pairs, one per `wayland.*` permission
  # in each app's *effective* granted set (granted − denied).
  # Empty list → empty file; safe to keep generating unconditionally
  # since the file is documented and no-cost to emit.
  waylandPermissionLines = lib.concatLists (
    lib.mapAttrsToList (
      _name: app:
      let
        effective = effectiveOf app;
        waylandPerms = lib.filter (p: lib.hasPrefix "wayland." p) effective;
      in
      map (perm: "${app.appId} ${perm}") waylandPerms
    ) cfg
  );

  waylandPermissionsFile = pkgs.writeText "spaces-wayland-permissions.txt" ''
    # Auto-generated by services.spaces.apps.<name>.permissions.granted
    # — one "<app-id> <permission>" line per wayland.* entry. The
    # patched niri (see patches/niri-per-permission-gating.patch.draft)
    # reads this at startup to gate restricted Wayland-protocol
    # globals per app-id. Until that patch lands the file is
    # informational only.
    ${lib.concatStringsSep "\n" waylandPermissionLines}
  '';

  # Any app holding `wm.spawn-named-tasks` (granted, ignoring denied)
  # needs the coordinator running to be useful. We start the unit
  # whenever the manifest is non-empty — the coordinator is cheap
  # (single Go goroutine on a Unix socket) and the surface area of
  # "is it up?" is one less thing to think about.
  anyAppNeedsCoordinator = builtins.any (
    app: builtins.elem "wm.spawn-named-tasks" (effectiveOf app)
  ) (lib.attrValues cfg);

  # ── Operator-clarity lint: require explicit ^…$ on allowedArgs ──────
  # The coordinator already anchors every pattern to a full-string match
  # (`\A(?:…)\z` in app-coordinator/server.go), so an unanchored pattern
  # can no longer leak a substring match. We still require operators to
  # bracket every pattern with `^` and `$` so manifest intent is explicit
  # at a glance. Operators who really want "allow anything" spell it `^.*$`.
  unanchoredArgs = lib.concatLists (
    lib.mapAttrsToList (
      name: app:
      map (p: { inherit name p; }) (
        lib.filter (p: !(lib.hasPrefix "^" p && lib.hasSuffix "$" p)) app.allowedArgs
      )
    ) cfg
  );
in
{
  options.services.spaces.apps = lib.mkOption {
    type = lib.types.attrsOf appSubmodule;
    default = { };
    description = ''
      Declarative, manifest-driven application sandbox registry.

      Each entry under `services.spaces.apps.<name>` declares an app,
      the permissions it has been granted (effective at launch), the
      permissions it has requested (surfaced in the permission UI),
      and a private state directory. The module generates
      `app-run-<name>` on the system PATH; that launcher spawns the
      app under `systemd-run --user --scope` with sandbox properties
      derived from the resolved permission set (`granted` minus
      `denied`).

      The catalogue of recognised permissions is closed and validated
      by the option type — adding a new permission means updating the
      `knownPermissions` table in `modules/nixos/apps.nix` so each
      one is documented once and consulted everywhere.
    '';
    example = lib.literalExpression ''
      {
        firefox = {
          package = pkgs.firefox;
          permissions.granted = [ "network" "wayland" "audio.playback" "dri" ];
          permissions.requested = [ "audio.record" "fs.user-files" ];
        };

        agent = {
          package = pkgs.my-agent;
          permissions.granted = [
            "wayland"
            "wm.foreign-toplevel-management"
            "wm.spawn-named-tasks"
          ];
          permissions.denied = [ "network" "audio.record" ];
        };
      }
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = unanchoredArgs == [ ];
        message = ''
            services.spaces.apps: the following allowedArgs patterns
            are not anchored (must start with ^ and end with $). Go's
            regexp.MatchString finds *substrings*, so an unanchored
            pattern accepts much more than it appears to — e.g.
            `--profile=[a-z]+` matches `evil --profile=alice` because
            the `e` of `evil` starts a substring match.

            Wrap each pattern with ^ and $. Use `^.*$` if you really
            mean "allow anything" (which should be rare and reviewable).

          ${lib.concatMapStringsSep "\n" (
            e: "          - services.spaces.apps.${e.name}.allowedArgs: ${e.p}"
          ) unanchoredArgs}
        '';
      }
    ];

    environment.systemPackages = lib.attrValues launchers ++ [
      # Operator CLI — `spaces-apps list / info / running / kill / spawn`.
      # Wraps the coordinator's line-JSON protocol.
      spacesAppsCliPkg
    ];

    environment.etc."spaces/app-coordinator/manifest.json".source = manifestFile;
    environment.etc."spaces/wayland-permissions.txt".source = waylandPermissionsFile;
    environment.etc."spaces/permissions.json".source = permissionsFile;

    systemd.user.services.spaces-app-coordinator = lib.mkIf anyAppNeedsCoordinator {
      description = "spaces app-coordinator: mediated launcher for sandboxed callers";
      # The coordinator itself does not depend on Wayland — it spawns
      # other apps, some of which may, but those apps' launchers
      # handle that. Wire to default.target so a headless / SSH
      # session has the coordinator up too.
      wantedBy = [ "default.target" ];
      # Restart when the manifest changes so a system-rebuild that
      # adds or removes an app is picked up without a reboot.
      restartTriggers = [ manifestFile ];
      serviceConfig = {
        ExecStart = lib.getExe coordinatorPkg;
        Restart = "on-failure";
        RestartSec = 3;
        # The coordinator forks into launcher subprocesses that exec
        # systemd-run; PATH needs the standard set so systemd-run
        # itself is resolvable.
        Environment = [
          "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
          "APP_COORDINATOR_MANIFEST=${coordinatorManifestPath}"
        ];
      };
    };
  };
}
