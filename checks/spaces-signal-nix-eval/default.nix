# Cheap nix-eval contract for the spaces-signal NixOS module.
#
# Verifies:
#   1. Enabling services.spaces-signal materialises the right
#      systemd.user.spaces-signal-cli unit (ExecStart contains the
#      daemon args we promise; RuntimeDirectory is set).
#   2. The module publishes the message store (read-only) and the
#      bridge's sandbox runtime dir (read-write) into
#      services.pi-chat.sandboxAllowedPaths, which pi-chat forwards into the
#      daemon's SPACES_SESSIOND_ALLOWED_PATHS env JSON (the per-session
#      sandbox bind list of pi-sessiond) — and crucially does NOT
#      publish the signal-cli daemon socket or panel.sock, so a
#      prompt-injected agent can read messages and queue sends but can
#      neither reach the daemon directly nor mint its own approval.
#   3. Enabling spaces-signal without pi-chat trips the module's own
#      assertion (the integration is meaningless without the agent).
#   4. Default-on follows pi-chat: an unconfigured spaces host
#      (which auto-enables pi-chat) ships the signal-cli infra by
#      default; an explicit `services.spaces-signal.enable = false`
#      strips it back out.
#   5. Both user services carry ConditionPathExistsGlob so they
#      silently no-op until the user runs `signal-cli link`; a
#      systemd.user.paths.spaces-signal-link unit watches for the
#      account dir and triggers the daemon on first link; the bridge
#      follows the daemon via wantedBy so it auto-starts in lockstep.
#
# Pure nix eval + jq. ~3-5s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  baseModules = [
    # spaces -> pi-chat imports the signal-cli module
    # transitively, so the eval here exercises the same import
    # graph spaces users get.
    inputs.self.nixosModules.spaces
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

  # Default deployment shape: spaces module (which auto-enables
  # pi-chat) plus an explicit `enable = true` on spaces-signal. The
  # explicit set is redundant with the new pi-chat-tracking default
  # but keeps the intent obvious next to the assertions below.
  enabledSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = baseModules ++ [
      {
        networking.hostName = "signal-enabled";
        services.spaces-signal.enable = true;
      }
    ];
  };

  # Opt-out path: same imports, explicit `enable = false`. Must
  # leave NO spaces-signal-* user units, NO sandbox binds, and the
  # signal skill must not reach the agent's skills-defs farm.
  disabledSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = baseModules ++ [
      {
        networking.hostName = "signal-disabled";
        services.spaces-signal.enable = false;
      }
    ];
  };

  # No spaces / pi-chat in the import chain — spaces-signal
  # alone should trip its own assertion.
  brokenSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.signal-cli
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        networking.hostName = "signal-no-pichat";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";

        services.spaces-signal.enable = true;
      }
    ];
  };

  brokenAttempt = builtins.tryEval (
    builtins.deepSeq brokenSystem.config.system.build.toplevel.drvPath null
  );

  service = enabledSystem.config.systemd.user.services.spaces-signal-cli;
  bridge = enabledSystem.config.systemd.user.services.spaces-signal-bridge;
  pathUnit = enabledSystem.config.systemd.user.paths.spaces-signal-link;
  # The bind list the daemon folds into every per-session sandbox.
  # services.pi-chat.sandboxAllowedPaths forwards into
  # services.pi-sessiond.allowedPaths, serialized as JSON into the
  # daemon user unit's environment.
  allowedPathsEnv =
    system: system.config.systemd.user.services.pi-sessiond.environment.SPACES_SESSIOND_ALLOWED_PATHS;
  # The env JSON the daemon --setenv's into every per-session sandbox.
  # services.pi-chat.sandboxEnv forwards into pi-sessiond.sessionEnv;
  # the in-sandbox `signal` CLI reads SPACES_SIGNAL_DB from here.
  sessionEnvJson =
    system: system.config.systemd.user.services.pi-sessiond.environment.SPACES_SESSIOND_SESSION_ENV;
in
pkgs.runCommand "spaces-signal-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    allowedPaths = allowedPathsEnv enabledSystem;
    execStart = service.serviceConfig.ExecStart;
    runtimeDir = service.serviceConfig.RuntimeDirectory or "";
    runtimeDirMode = service.serviceConfig.RuntimeDirectoryMode or "";
    serviceType = service.serviceConfig.Type or "";
    restart = service.serviceConfig.Restart or "";
    wantedBy = lib.concatStringsSep " " service.wantedBy;
    bridgeExecStart = bridge.serviceConfig.ExecStart;
    bridgeRequires = lib.concatStringsSep " " (bridge.requires or [ ]);
    bridgeAfter = lib.concatStringsSep " " (bridge.after or [ ]);
    bridgeRestart = bridge.serviceConfig.Restart or "";
    brokenSucceeded = if brokenAttempt.success then "yes" else "no";
    enabledTmpfiles = lib.concatStringsSep "\n" enabledSystem.config.systemd.user.tmpfiles.rules;
    disabledTmpfiles = lib.concatStringsSep "\n" disabledSystem.config.systemd.user.tmpfiles.rules;
    # Condition that gates both user units. Empty when not set, which
    # makes the assertion below fail clearly instead of silently
    # treating "no condition" as a match.
    serviceCondition = lib.concatStringsSep " " (
      lib.toList (service.unitConfig.ConditionPathExistsGlob or [ ])
    );
    bridgeCondition = lib.concatStringsSep " " (
      lib.toList (bridge.unitConfig.ConditionPathExistsGlob or [ ])
    );
    # Path-activation unit: starts the daemon when an account dir
    # first appears under ~/.local/share/signal-cli/data/.
    pathExistsGlob = lib.concatStringsSep " " (lib.toList (pathUnit.pathConfig.PathExistsGlob or [ ]));
    pathUnitTarget = pathUnit.pathConfig.Unit or "";
    pathUnitWantedBy = lib.concatStringsSep " " (pathUnit.wantedBy or [ ]);
    # Bridge follows daemon: when the daemon is path-triggered, the
    # bridge must start too. wantedBy on the unit edge does that.
    bridgeWantedBy = lib.concatStringsSep " " (bridge.wantedBy or [ ]);
    # When the user opts out, spaces-signal-cli must NOT be declared
    # at all (not "declared but disabled"). Empty string = absent.
    disabledHasSignalUnits =
      let
        names = builtins.attrNames disabledSystem.config.systemd.user.services;
      in
      if builtins.elem "spaces-signal-cli" names then "yes" else "no";
    # Likewise the daemon bind list must not carry signal entries when
    # opted out — we surface the raw env JSON for a jq check.
    disabledAllowedPaths = allowedPathsEnv disabledSystem;
    sessionEnv = sessionEnvJson enabledSystem;
    disabledSessionEnv = sessionEnvJson disabledSystem;
  }
  ''
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # ── 1. systemd unit shape ────────────────────────────────────────
    case "$execStart" in
      *"signal-cli daemon"*)
        ;;
      *)
        fail "ExecStart does not invoke 'signal-cli daemon': $execStart"
        ;;
    esac

    for needle in "--socket" "--receive-mode=on-start" "--no-receive-stdout"; do
      case "$execStart" in
        *"$needle"*) ;;
        *) fail "ExecStart missing $needle: $execStart" ;;
      esac
    done

    [ "$runtimeDir"     = "signal-cli" ] || fail "RuntimeDirectory must be 'signal-cli', got '$runtimeDir'"
    [ "$runtimeDirMode" = "0700" ]       || fail "RuntimeDirectoryMode must be '0700', got '$runtimeDirMode'"
    [ "$serviceType"    = "exec" ]       || fail "service Type must be 'exec', got '$serviceType'"
    [ "$restart"        = "always" ]     || fail "Restart must be 'always', got '$restart'"

    case " $wantedBy " in
      *" default.target "*) ;;
      *) fail "unit must be wantedBy=default.target, got '$wantedBy'" ;;
    esac

    # ── 2. sandbox path-grant integration (SPACES_SESSIOND_ALLOWED_PATHS) ─
    jq -e . >/dev/null <<<"$allowedPaths" \
      || fail "SPACES_SESSIOND_ALLOWED_PATHS is not valid JSON: $allowedPaths"
    jq -e '
      all(.source != "%t/signal-cli/socket")
    ' >/dev/null <<<"$allowedPaths" \
      || fail "signal-cli daemon socket MUST NOT be in the sandbox allowlist (security regression — agent would bypass the approval gate): $allowedPaths"
    jq -e '
      any(.source == "%h/.local/state/spaces/signal" and .mode == "ro")
    ' >/dev/null <<<"$allowedPaths" \
      || fail "signal store dir must be RO in the sandbox allowlist (sandbox writes would forge messages / fake approvals): $allowedPaths"
    jq -e '
      any(.source == "%h/.local/share/signal-cli/attachments" and .mode == "ro")
    ' >/dev/null <<<"$allowedPaths" \
      || fail "signal-cli attachments dir not in the sandbox allowlist: $allowedPaths"

    # ── 2*. The signal store's absolute path is published into the
    # sandbox env (SPACES_SESSIOND_SESSION_ENV → SPACES_SIGNAL_DB). The
    # in-sandbox `signal` CLI resolves messages.db from this var; without
    # it the CLI falls back to $HOME/.local/state/spaces/signal, but the
    # sandbox $HOME is a private per-session agent dir, NOT the login home
    # where the RO bind above grants the store — so reads would hit a
    # nonexistent path. This couples the published env to the bind source.
    jq -e . >/dev/null <<<"$sessionEnv" \
      || fail "SPACES_SESSIOND_SESSION_ENV is not valid JSON: $sessionEnv"
    jq -e '
      .SPACES_SIGNAL_DB == "%h/.local/state/spaces/signal/messages.db"
    ' >/dev/null <<<"$sessionEnv" \
      || fail "signal store path not published to the sandbox env (the in-sandbox CLI would resolve messages.db under the remapped sandbox HOME and miss the RO-granted store): $sessionEnv"

    # ── 2b. bridge unit shape ────────────────────────────────────────
    case "$bridgeExecStart" in
      */bin/spaces-signal-bridge) ;;
      *) fail "bridge ExecStart must be /…/bin/spaces-signal-bridge, got '$bridgeExecStart'" ;;
    esac
    case " $bridgeRequires " in
      *" spaces-signal-cli.service "*) ;;
      *) fail "bridge must require spaces-signal-cli.service, got '$bridgeRequires'" ;;
    esac
    case " $bridgeAfter " in
      *" spaces-signal-cli.service "*) ;;
      *) fail "bridge must come after spaces-signal-cli.service, got '$bridgeAfter'" ;;
    esac
    [ "$bridgeRestart" = "always" ] || fail "bridge Restart must be 'always', got '$bridgeRestart'"

    # ── 2c. The sandbox bind-mounts a *directory*, not a socket file,
    # and specifically the inner `sandbox/` subdir. Binding the dir
    # fixes the spawn-time race: the dir always exists (created
    # unconditionally by tmpfiles below), the bind succeeds, and the
    # enqueue socket the bridge later creates inside the dir becomes
    # visible inside the sandbox automatically. tmpfiles creates the dir
    # unconditionally so the Landlock grant always applies (the launcher
    # silently skips a grant whose source path is missing).
    jq -e '
      any(.source == "%t/spaces-signal/sandbox" and .mode == "rw")
    ' >/dev/null <<<"$allowedPaths" \
      || fail "spaces-signal sandbox subdir must be in the sandbox allowlist (rw): $allowedPaths"

    # ── 2d. The panel socket — and the parent dir that contains it —
    # MUST stay out of the sandbox. That's the security boundary: a
    # prompt-injected agent can post to enqueue.sock but cannot mint
    # an approval on panel.sock. Reject any bind whose source could
    # expose the panel socket, including the parent `spaces-signal/`
    # dir, the panel file itself, or the legacy flat names.
    jq -e '
      all(.source != "%t/spaces-signal"
            and .source != "%t/spaces-signal/panel.sock"
            and .source != "%t/spaces-signal/sandbox/panel.sock"
            and .source != "%t/spaces-signal-panel.sock"
            and .source != "%t/spaces-signal-enqueue.sock")
    ' >/dev/null <<<"$allowedPaths" \
      || fail "sandbox allowlist exposes the panel socket or its parent dir (security regression — agent could self-approve sends): $allowedPaths"

    # ── 2e. Both runtime dirs are created unconditionally by user-
    # tmpfiles, so the mandatory bind above succeeds even on hosts
    # that have never linked Signal. We need *both* lines: the parent
    # holds the host-only panel socket, the child is the sandbox bind
    # source.
    case "$enabledTmpfiles" in
      *"d %t/spaces-signal 0700"*) ;;
      *) fail "user-tmpfiles must create %t/spaces-signal 0700 unconditionally: $enabledTmpfiles" ;;
    esac
    case "$enabledTmpfiles" in
      *"d %t/spaces-signal/sandbox 0700"*) ;;
      *) fail "user-tmpfiles must create %t/spaces-signal/sandbox 0700 unconditionally (sandbox bind source): $enabledTmpfiles" ;;
    esac

    # ── 2f. signal SKILL.md is included by default (since enable
    # tracks pi-chat.enable) and stripped when explicitly disabled.
    # Guards against the agent advertising a CLI the sandbox doesn't
    # actually ship. The skill is materialised as a symlink line in
    # the user-tmpfiles rules.
    case "$enabledTmpfiles" in
      *"/skills-defs/signal "*) ;;
      *) fail "signal SKILL.md never reached pi-chat skills-defs when spaces-signal is enabled." ;;
    esac
    case "$disabledTmpfiles" in
      *"/skills-defs/signal "*) fail "signal SKILL.md still present after services.spaces-signal.enable = false." ;;
      *) ;;
    esac

    # ── 2g. ConditionPathExistsGlob gates both units so they no-op
    # silently until the user runs `signal-cli link`. Without this
    # the daemon spins a JVM at every login for nothing on fresh
    # systems; with it, login does not start signal-cli until an
    # account dir appears.
    expectedGlob='%h/.local/share/signal-cli/data/*.d'
    [ "$serviceCondition" = "$expectedGlob" ] \
      || fail "daemon ConditionPathExistsGlob must be '$expectedGlob', got '$serviceCondition'"
    [ "$bridgeCondition" = "$expectedGlob" ] \
      || fail "bridge ConditionPathExistsGlob must be '$expectedGlob', got '$bridgeCondition'"

    # ── 2h. systemd.user.paths.spaces-signal-link auto-starts the
    # daemon when the account dir is created by `signal-cli link`.
    # Without this the first link requires a manual `systemctl
    # --user start` — defeats the auto-onboarding goal.
    [ "$pathExistsGlob" = "$expectedGlob" ] \
      || fail "path-unit PathExistsGlob must be '$expectedGlob', got '$pathExistsGlob'"
    [ "$pathUnitTarget" = "spaces-signal-cli.service" ] \
      || fail "path-unit must target spaces-signal-cli.service, got '$pathUnitTarget'"
    case " $pathUnitWantedBy " in
      *" default.target "*) ;;
      *) fail "path-unit must be wantedBy=default.target so login arms it, got '$pathUnitWantedBy'" ;;
    esac

    # ── 2i. Bridge follows daemon. The path-unit only triggers the
    # daemon; the bridge must be wantedBy that daemon so it comes
    # up in lockstep when the first link happens.
    case " $bridgeWantedBy " in
      *" spaces-signal-cli.service "*) ;;
      *) fail "bridge must be wantedBy=spaces-signal-cli.service (so path-activation propagates), got '$bridgeWantedBy'" ;;
    esac

    # ── 2j. Opt-out path: explicit `enable = false` strips every
    # signal-cli-shaped artifact from the system, including the user
    # units and the daemon's sandbox binds.
    [ "$disabledHasSignalUnits" = "no" ] \
      || fail "spaces-signal-cli unit still declared after explicit enable = false"
    jq -e '
      all(.source | startswith("%t/signal-cli/") | not)
      and all(.source | startswith("%h/.local/state/spaces/signal") | not)
      and all(.source | startswith("%t/spaces-signal") | not)
    ' >/dev/null <<<"$disabledAllowedPaths" \
      || fail "daemon sandbox allowlist still carries signal-cli entries after explicit enable = false: $disabledAllowedPaths"
    jq -e '.SPACES_SIGNAL_DB == null' >/dev/null <<<"$disabledSessionEnv" \
      || fail "sandbox env still publishes SPACES_SIGNAL_DB after explicit enable = false: $disabledSessionEnv"

    # ── 3. spaces-signal without pi-chat must fail eval ──────────────
    if [ "$brokenSucceeded" = "yes" ]; then
      fail "spaces-signal evaluated cleanly without pi-chat; the assertion is missing or stopped catching this combo."
    fi

    echo "OK"
    touch "$out"
  ''
