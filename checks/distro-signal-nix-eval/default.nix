# Cheap nix-eval contract for the distro-signal NixOS module.
#
# Verifies:
#   1. Enabling services.distro-signal materialises the right
#      systemd.user.distro-signal-cli unit (ExecStart contains the
#      daemon args we promise; RuntimeDirectory is set).
#   2. The module publishes the signal-cli socket + store dirs into
#      services.pi-chat.sandboxBinds, so the agent's read CLI can
#      reach the daemon and the message DB through the per-session
#      sandbox.
#   3. Enabling distro-signal without pi-chat trips the module's own
#      assertion (the integration is meaningless without the agent).
#   4. Default-on follows pi-chat: an unconfigured distro host
#      (which auto-enables pi-chat) ships the signal-cli infra by
#      default; an explicit `services.distro-signal.enable = false`
#      strips it back out.
#   5. Both user services carry ConditionPathExistsGlob so they
#      silently no-op until the user runs `signal-cli link`; a
#      systemd.user.paths.distro-signal-link unit watches for the
#      account dir and triggers the daemon on first link; the bridge
#      follows the daemon via wantedBy so it auto-starts in lockstep.
#
# Pure nix eval + jq. ~3-5s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  baseModules = [
    # distro -> pi-chat imports the signal-cli module
    # transitively, so the eval here exercises the same import
    # graph distro users get.
    inputs.self.nixosModules.distro
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

  # Default deployment shape: distro module (which auto-enables
  # pi-chat) plus an explicit `enable = true` on distro-signal. The
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
        services.distro-signal.enable = true;
      }
    ];
  };

  # Opt-out path: same imports, explicit `enable = false`. Must
  # leave NO distro-signal-* user units, NO sandbox binds, and the
  # signal skill must not reach the agent's skills-defs farm.
  disabledSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = baseModules ++ [
      {
        networking.hostName = "signal-disabled";
        services.distro-signal.enable = false;
      }
    ];
  };

  # No distro / pi-chat in the import chain — distro-signal
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

        services.distro-signal.enable = true;
      }
    ];
  };

  brokenAttempt = builtins.tryEval (
    builtins.deepSeq brokenSystem.config.system.build.toplevel.drvPath null
  );

  service = enabledSystem.config.systemd.user.services.distro-signal-cli;
  bridge = enabledSystem.config.systemd.user.services.distro-signal-bridge;
  pathUnit = enabledSystem.config.systemd.user.paths.distro-signal-link;
  pichatConfig = enabledSystem.config.environment.etc."distro/pi-chat.json".source;
  disabledPichatCfg = disabledSystem.config.environment.etc."distro/pi-chat.json";
in
pkgs.runCommand "distro-signal-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit pichatConfig;
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
    # When the user opts out, distro-signal-cli must NOT be declared
    # at all (not "declared but disabled"). Empty string = absent.
    disabledHasSignalUnits =
      let
        names = builtins.attrNames disabledSystem.config.systemd.user.services;
      in
      if builtins.elem "distro-signal-cli" names then "yes" else "no";
    # Likewise sandboxBinds must not carry signal entries when opted
    # out — we surface the raw JSON for a jq check.
    disabledPichatConfig = disabledPichatCfg.source;
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

    # ── 2. sandboxBinds integration ──────────────────────────────────
    jq -e . "$pichatConfig" >/dev/null || fail "$pichatConfig is not valid JSON"

    binds=$(jq -c '.sandboxBinds' "$pichatConfig")

    jq -e '
      .sandboxBinds
      | all(.source != "%t/signal-cli/socket")
    ' "$pichatConfig" >/dev/null \
      || fail "signal-cli daemon socket MUST NOT be in sandboxBinds (security regression — agent would bypass the approval gate): $binds"

    jq -e '
      .sandboxBinds
      | any(.source == "%h/.local/state/distro/signal" and .mode == "ro" and .optional == false)
    ' "$pichatConfig" >/dev/null \
      || fail "signal store dir must be RO in sandboxBinds (sandbox writes would forge messages / fake approvals): $binds"

    jq -e '
      .sandboxBinds
      | any(.source == "%h/.local/share/signal-cli/attachments" and .mode == "ro" and .optional == true)
    ' "$pichatConfig" >/dev/null \
      || fail "signal-cli attachments dir not in sandboxBinds: $binds"

    # ── 2b. bridge unit shape ────────────────────────────────────────
    case "$bridgeExecStart" in
      */bin/distro-signal-bridge) ;;
      *) fail "bridge ExecStart must be /…/bin/distro-signal-bridge, got '$bridgeExecStart'" ;;
    esac
    case " $bridgeRequires " in
      *" distro-signal-cli.service "*) ;;
      *) fail "bridge must require distro-signal-cli.service, got '$bridgeRequires'" ;;
    esac
    case " $bridgeAfter " in
      *" distro-signal-cli.service "*) ;;
      *) fail "bridge must come after distro-signal-cli.service, got '$bridgeAfter'" ;;
    esac
    [ "$bridgeRestart" = "always" ] || fail "bridge Restart must be 'always', got '$bridgeRestart'"

    # ── 2c. The sandbox bind-mounts a *directory*, not a socket file,
    # and specifically the inner `sandbox/` subdir. Binding the dir
    # fixes the spawn-time race: the dir always exists (created
    # unconditionally by tmpfiles below), the bind succeeds, and the
    # enqueue socket the bridge later creates inside the dir becomes
    # visible inside the sandbox automatically. Mandatory (not
    # optional) — if this ever drops back to optional we re-introduce
    # the silent-skip race.
    jq -e '
      .sandboxBinds
      | any(.source == "%t/distro-signal/sandbox" and .mode == "rw" and (.optional // false) == false)
    ' "$pichatConfig" >/dev/null \
      || fail "distro-signal sandbox subdir must be in sandboxBinds (rw, mandatory): $binds"

    # ── 2d. The panel socket — and the parent dir that contains it —
    # MUST stay out of the sandbox. That's the security boundary: a
    # prompt-injected agent can post to enqueue.sock but cannot mint
    # an approval on panel.sock. Reject any bind whose source could
    # expose the panel socket, including the parent `distro-signal/`
    # dir, the panel file itself, or the legacy flat names.
    jq -e '
      .sandboxBinds
      | all(.source != "%t/distro-signal"
            and .source != "%t/distro-signal/panel.sock"
            and .source != "%t/distro-signal/sandbox/panel.sock"
            and .source != "%t/distro-signal-panel.sock"
            and .source != "%t/distro-signal-enqueue.sock")
    ' "$pichatConfig" >/dev/null \
      || fail "sandboxBinds exposes the panel socket or its parent dir (security regression — agent could self-approve sends): $binds"

    # ── 2e. Both runtime dirs are created unconditionally by user-
    # tmpfiles, so the mandatory bind above succeeds even on hosts
    # that have never linked Signal. We need *both* lines: the parent
    # holds the host-only panel socket, the child is the sandbox bind
    # source.
    case "$enabledTmpfiles" in
      *"d %t/distro-signal 0700"*) ;;
      *) fail "user-tmpfiles must create %t/distro-signal 0700 unconditionally: $enabledTmpfiles" ;;
    esac
    case "$enabledTmpfiles" in
      *"d %t/distro-signal/sandbox 0700"*) ;;
      *) fail "user-tmpfiles must create %t/distro-signal/sandbox 0700 unconditionally (sandbox bind source): $enabledTmpfiles" ;;
    esac

    # ── 2f. signal SKILL.md is included by default (since enable
    # tracks pi-chat.enable) and stripped when explicitly disabled.
    # Guards against the agent advertising a CLI the sandbox doesn't
    # actually ship. The skill is materialised as a symlink line in
    # the user-tmpfiles rules.
    case "$enabledTmpfiles" in
      *"/skills-defs/signal "*) ;;
      *) fail "signal SKILL.md never reached pi-chat skills-defs when distro-signal is enabled." ;;
    esac
    case "$disabledTmpfiles" in
      *"/skills-defs/signal "*) fail "signal SKILL.md still present after services.distro-signal.enable = false." ;;
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

    # ── 2h. systemd.user.paths.distro-signal-link auto-starts the
    # daemon when the account dir is created by `signal-cli link`.
    # Without this the first link requires a manual `systemctl
    # --user start` — defeats the auto-onboarding goal.
    [ "$pathExistsGlob" = "$expectedGlob" ] \
      || fail "path-unit PathExistsGlob must be '$expectedGlob', got '$pathExistsGlob'"
    [ "$pathUnitTarget" = "distro-signal-cli.service" ] \
      || fail "path-unit must target distro-signal-cli.service, got '$pathUnitTarget'"
    case " $pathUnitWantedBy " in
      *" default.target "*) ;;
      *) fail "path-unit must be wantedBy=default.target so login arms it, got '$pathUnitWantedBy'" ;;
    esac

    # ── 2i. Bridge follows daemon. The path-unit only triggers the
    # daemon; the bridge must be wantedBy that daemon so it comes
    # up in lockstep when the first link happens.
    case " $bridgeWantedBy " in
      *" distro-signal-cli.service "*) ;;
      *) fail "bridge must be wantedBy=distro-signal-cli.service (so path-activation propagates), got '$bridgeWantedBy'" ;;
    esac

    # ── 2j. Opt-out path: explicit `enable = false` strips every
    # signal-cli-shaped artifact from the system, including the user
    # units and the pi-chat sandbox binds.
    [ "$disabledHasSignalUnits" = "no" ] \
      || fail "distro-signal-cli unit still declared after explicit enable = false"
    jq -e '
      .sandboxBinds
      | all(.source | startswith("%t/signal-cli/") | not)
      and all(.source | startswith("%h/.local/state/distro/signal") | not)
      and all(.source | startswith("%t/distro-signal") | not)
    ' "$disabledPichatConfig" >/dev/null \
      || fail "sandboxBinds still carry signal-cli entries after explicit enable = false: $(jq -c '.sandboxBinds' "$disabledPichatConfig")"

    # ── 3. distro-signal without pi-chat must fail eval ──────────────
    if [ "$brokenSucceeded" = "yes" ]; then
      fail "distro-signal evaluated cleanly without pi-chat; the assertion is missing or stopped catching this combo."
    fi

    echo "OK"
    touch "$out"
  ''
