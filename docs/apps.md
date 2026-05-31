# `services.spaces.apps` — manifest-driven sandbox model

Operator reference for the per-app sandbox subsystem. Architecture
notes live in code comments; this document is the consolidated
"how do I use it" view.

## TL;DR

- Each app is a NixOS module entry under `services.spaces.apps.<name>`.
- A per-app launcher (`app-run-<name>`) lands on the system PATH at
  build time. Running it spawns the app inside a hardened sandbox.
- A coordinator daemon (`spaces-app-coordinator.service`, per-user)
  mediates launches from sandboxed callers and enforces per-app
  `spawnableBy` allow-lists.
- Runtime grants (operator-controlled, at
  `~/.local/state/spaces/grants/<appId>.json`) can add to a
  manifest's `granted` set without a rebuild — but `permissions.denied`
  is always applied last and cannot be bypassed.
- The `spaces-apps` CLI wraps everything.

## Schema

```nix
services.spaces.apps.firefox = {
  package = pkgs.firefox;
  exec = null;                          # optional override; defaults to lib.getExe
  args = [ "--no-first-run" ];          # static args, baked at eval time

  permissions = {
    granted   = [ "network" "wayland" "audio.playback" "dri" ];
    requested = [ "audio.record" ];     # documentation only; surfaced in UI
    denied    = [ ];                    # operator's hard deny — always wins
  };

  allowedArgs = [                       # regex allow-list for caller-supplied argv
    "^https?://.+$"
    "^--profile=[a-zA-Z0-9-]+$"
  ];

  spawnableBy = [ "*" ];                # which apps can spawn this via the coordinator;
                                        # "host" matches any non-sandboxed caller
                                        # default: [ "*" ]

  dbusSession = {                       # per-app xdg-dbus-proxy filter
    talk      = [ "org.freedesktop.Notifications" "org.freedesktop.portal.*" ];
    own       = [ ];
    see       = [ ];
    call      = [ ];
    broadcast = [ ];
  };

  credentials = {                       # systemd LoadCredential= passthrough
    api-key = "/run/spaces-secrets/firefox-key";
  };

  extraBinds = [                        # additional bind-mounts
    { source = "$XDG_RUNTIME_DIR/foo"; mode = "rw"; }
  ];

  resources = {                         # systemd resource limits
    memoryHigh = "4G";                  # default 2G
    tasksMax   = 2048;                  # default 1024
  };

  waylandSandbox = true;                # default true. Set to false for apps that
                                        # need restricted Wayland protocols
                                        # (virtual-keyboard, screen-capture, …)
                                        # — see waylandSandbox notes below.

  stateDir = ".local/share/spaces/apps/firefox";
                                        # bind-mounted to /home/app inside the sandbox

  appId = "spaces.app.firefox";         # reverse-DNS id; surfaces in security-context
                                        # and the runtime-grant file name
};
```

All fields are optional except `package` (or `exec`).

## Permission catalogue

Each permission opens one capability hole. See `spaces-apps permissions`
for the live catalogue with descriptions:

| Permission | Effect |
|---|---|
| `network` | Without this, the sandbox runs with `PrivateNetwork=true`. |
| `wayland` | Connect to the user's Wayland compositor. |
| `audio.playback` / `audio.record` | Pipewire/Pulse playback/mic socket. |
| `dri` | GPU access via `/dev/dri/*`. |
| `fs.user-files` | Read-only bind of `~/Documents`, `~/Pictures`, `~/Downloads`. |
| `xwayland` | Access XWayland (note: X11 clients can keylog each other). |
| `wm.spawn-named-tasks` | Coordinator may launch other manifested apps on this app's behalf. |
| `wayland.layer-shell` | `zwlr_layer_shell_v1` (panels, bars). |
| `wayland.session-lock` | `ext_session_lock_manager_v1`. |
| `wayland.data-control` | `wlr/ext_data_control` (clipboard read). |
| `wayland.input-method` | `zwp_input_method_manager_v2`. |
| `wayland.virtual-keyboard` | `zwp_virtual_keyboard_manager_v1` (synthetic keystrokes). |
| `wayland.virtual-pointer` | `zwlr_virtual_pointer_manager_v1`. |
| `wayland.foreign-toplevel-management` | enumerate/activate other apps' windows. |
| `wayland.ext-workspace` | `ext_workspace_manager_v1`. |
| `wayland.output-management` | `zwlr_output_manager_v1` (configure displays). |
| `wayland.screen-capture` | `zwlr_screencopy_manager_v1`. |

The `wayland.*` permissions are gated by the patched niri compositor;
until `patches/niri-per-permission-gating.patch.draft` lands they reach
`/etc/spaces/wayland-permissions.txt` as a declaration but Niri still
binary-gates on the security-context restricted flag.

## Sandbox baseline

Every app gets, regardless of grants:

- `PrivateTmp=true` + `ProtectHome=tmpfs` (own /tmp, /home masked)
- `ProtectSystem=full`, `ProtectKernelTunables/Modules/Logs=true`
- `NoNewPrivileges=true`, `CapabilityBoundingSet=` (empty), `AmbientCapabilities=` (empty)
- `LockPersonality=true`, `RestrictNamespaces=true`, `RestrictRealtime=true`
- `SystemCallFilter=@system-service ~@privileged @resources @swap @reboot @module @mount @raw-io @cpu-emulation @obsolete @debug`
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`
- `KeyringMode=private`, `UMask=0077`
- `InaccessiblePaths=-/run/secrets -/run/agenix.d -/run/spaces-secrets`
- `MemoryHigh=2G`, `TasksMax=1024` (per-app override via `resources.*`)
- `XDG_SECURITY_CONTEXT_APP_ID` + `XDG_SECURITY_CONTEXT_SANDBOX_ENGINE` env
- `HOME=/home/app`, bind-mounted from `~/<stateDir>`

`ProcSubset=pid` / `ProtectProc=invisible` are accepted by systemd but
silently inert under `--user` (need `CAP_SYS_ADMIN` to remount /proc).
Documented in the launcher.

## Runtime grants

```bash
$ spaces-apps grant browser network         # add to ~/.local/state/spaces/grants/spaces.app.browser.json
$ spaces-apps grants browser                # show current
$ spaces-apps revoke browser network        # remove
```

The launcher reads the file at every spawn, unions the entries with
`permissions.granted`, then subtracts `permissions.denied`. The static
deny is the load-bearing security property — a runtime grant cannot
re-enable a permission the operator has hard-denied.

Stale grant files (for apps no longer in the manifest) can be reaped:

```bash
$ spaces-apps cleanup                       # dry-run; lists what's stale
$ spaces-apps --apply cleanup               # actually remove
```

## CLI reference

All commands support `--json` for `jq` consumption. Flags must precede
the subcommand name (Go convention).

| Command | What |
|---|---|
| `list` | All apps in the manifest |
| `info <name>` | Manifest entry (add `--describe` for permission descriptions) |
| `running` | Currently running app units |
| `spawn <name> [args]` | Launch via coordinator |
| `kill <unit>` | Stop a running unit |
| `logs <unit> [-f]` | Tail a unit's journal |
| `audit [-n N]` | Coordinator action timeline (request side) |
| `spawns [-n N]` | Launcher engagement timeline (effective permissions) |
| `verify` | Diagnose the wiring (socket, service, manifest, launchers) |
| `permissions` | Print the catalogue |
| `grants <name>` | Show runtime grants for one app |
| `grant <name> <perm>` | Add a runtime grant |
| `revoke <name> <perm>` | Remove a runtime grant |
| `cleanup [--apply]` | List/remove grant files for apps not in manifest |

Bash completion is shipped at the standard XDG location and is
context-aware: `grant <Tab>` only suggests un-granted permissions,
`revoke <Tab>` only suggests currently-granted ones.

## Trust model

**Coordinator socket** (`$XDG_RUNTIME_DIR/spaces-app-coordinator.sock`,
mode 0600) is only bind-mounted into sandboxes whose app declares
`wm.spawn-named-tasks` in `permissions.granted`. The coordinator
authenticates peers via `SO_PEERCRED` + `/proc/<pid>/cgroup`,
resolving to a `spaces.app.<name>` for sandboxed callers and `host`
otherwise; `spawnableBy` then decides whether the request is honored.

**Runtime grants** live under the user's `$HOME` and are user-mutable —
they're the right place for Android-style "allow this just for this
session" decisions. The `permissions.denied` baked at NixOS-build time
is the operator's veto.

**`waylandSandbox = false`**: when set, the launcher binds the Wayland
socket but skips the `wayland-app-context` security-context-v1 wrap.
The app sees the *full* Wayland registry, including restricted
protocols like `wlr-screencopy`, `virtual-keyboard`, etc. Use only for
apps that need a restricted protocol (e.g., voxtype's type-mode output
needs `virtual-keyboard`). The per-permission Niri patch (see
`patches/`) will obsolete this knob once it lands.

**Credentials**: stage system secrets at `/run/spaces-secrets/*` (mode
0640 root:users), declare them per-app via `credentials.<name> =
"/run/spaces-secrets/<name>"`. systemd's `LoadCredential=` exposes
each at `$CREDENTIALS_DIRECTORY/<name>` mode 0400 inside the unit.
The baseline `InaccessiblePaths=` masks the raw `/run/spaces-secrets`
dir from sandboxed apps that haven't explicitly declared a credential.

## Dynamic launch (`app-run-flake`)

For operator-driven "I want to try this random flake" usage there's a
separate CLI that takes a flake ref + explicit `--allow=...` /
`--dbus-talk=...` flags, builds the package, prompts for consent, and
launches inside the same sandbox model. Reuses the lib so no
divergence between static and dynamic paths.

```bash
$ app-run-flake --allow=wayland,network 'nixpkgs#firefox' -- https://example.com
```

Sandboxed apps (including the agent) cannot reach `app-run-flake` —
the closed-set guarantee from the static manifest is preserved.

## Files of interest

- `lib/apps-launcher.nix` — `mkLauncher`, `knownPermissions`, the bash
  launcher template. Single source of truth, consumed by both
  `modules/nixos/apps.nix` (static) and `app-run-flake` (dynamic).
- `modules/nixos/apps.nix` — NixOS module: option types, manifest
  generator, systemd user service for the coordinator.
- `packages/app-coordinator/` — Go daemon (line-JSON protocol, SO_PEERCRED).
- `packages/wayland-app-context/` — C helper, security-context-v1 client.
- `packages/spaces-apps/` — operator CLI (this is what you use day-to-day).
- `packages/app-run-flake/` — dynamic CLI.
- `checks/apps-coordinator.nix` — headless VM check (47 subtests).
- `checks/apps-coordinator-wayland.nix` — VM check with Niri (9 subtests).
- `patches/niri-per-permission-gating.patch.draft` — Niri patch design,
  awaiting hunk-header regeneration.
