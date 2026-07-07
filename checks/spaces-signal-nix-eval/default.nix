# Cheap nix-eval contract for the spaces-signal NixOS module.
#
# spaces-signal is now a pure daemon → messages.db forwarder: signal-cli
# runs as a JSON-RPC daemon and spaces-signal-bridge subscribes and
# persists envelopes into ~/.local/state/spaces/signal/messages.db, which
# the integration-signal MCP server reads. There is no agent-facing CLI,
# skill, sandbox bind, or send-approval socket left in this module — that
# surface moved to the integration (hosts/test-machine/integrations.nix).
#
# Verifies:
#   1. Enabling services.spaces-signal materialises the spaces-signal-cli
#      daemon unit (ExecStart daemon args; RuntimeDirectory + mode).
#   2. The spaces-signal-bridge forwarder unit runs the bridge binary,
#      requires/orders after the daemon, and restarts.
#   3. The store dir is created unconditionally by user-tmpfiles, and NO
#      signal skill reaches the pi-chat skills-defs farm (the skill is gone).
#   4. Both units carry ConditionPathExistsGlob so they no-op until the
#      user runs `signal-cli link`; a systemd.user.paths unit triggers the
#      daemon on first link and the bridge follows via wantedBy.
#   5. Enabling spaces-signal without pi-chat trips the module assertion.
#   6. An explicit enable = false strips every spaces-signal-* user unit.
#
# Pure nix eval. ~3-5s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  baseModules = [
    # spaces -> pi-chat imports the signal-cli module transitively, so the
    # eval here exercises the same import graph spaces users get.
    inputs.self.nixosModules.spaces
  ];

  mkSystem =
    extra:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = extra;
    };

  # Default deployment shape: spaces (auto-enables pi-chat) plus an
  # explicit `enable = true` on spaces-signal.
  enabledSystem = mkSystem (
    baseModules
    ++ [
      {
        networking.hostName = "signal-enabled";
        services.spaces-signal.enable = true;
      }
    ]
  );

  # Opt-out path: explicit `enable = false`. Must leave NO spaces-signal-*
  # user units.
  disabledSystem = mkSystem (
    baseModules
    ++ [
      {
        networking.hostName = "signal-disabled";
        services.spaces-signal.enable = false;
      }
    ]
  );

  # No spaces / pi-chat in the import chain — spaces-signal alone should
  # trip its own assertion.
  brokenSystem = mkSystem [
    inputs.self.nixosModules.signal-cli
    {
      networking.hostName = "signal-no-pichat";
      services.spaces-signal.enable = true;
    }
  ];

  brokenAttempt = builtins.tryEval (
    builtins.deepSeq brokenSystem.config.system.build.toplevel.drvPath null
  );

  service = enabledSystem.config.systemd.user.services.spaces-signal-cli;
  bridge = enabledSystem.config.systemd.user.services.spaces-signal-bridge;
  pathUnit = enabledSystem.config.systemd.user.paths.spaces-signal-link;
in
pkgs.runCommand "spaces-signal-nix-eval-test"
  {
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
    # Condition that gates both user units. Empty when not set, which makes
    # the assertion below fail clearly instead of silently matching.
    serviceCondition = lib.concatStringsSep " " (
      lib.toList (service.unitConfig.ConditionPathExistsGlob or [ ])
    );
    bridgeCondition = lib.concatStringsSep " " (
      lib.toList (bridge.unitConfig.ConditionPathExistsGlob or [ ])
    );
    # Path-activation unit: starts the daemon when an account dir first
    # appears under ~/.local/share/signal-cli/data/.
    pathExistsGlob = lib.concatStringsSep " " (lib.toList (pathUnit.pathConfig.PathExistsGlob or [ ]));
    pathUnitTarget = pathUnit.pathConfig.Unit or "";
    pathUnitWantedBy = lib.concatStringsSep " " (pathUnit.wantedBy or [ ]);
    # Bridge follows daemon: when the daemon is path-triggered, the bridge
    # must start too. wantedBy on the unit edge does that.
    bridgeWantedBy = lib.concatStringsSep " " (bridge.wantedBy or [ ]);
    # When the user opts out, spaces-signal-cli must NOT be declared at all
    # (not "declared but disabled"). Empty string = absent.
    disabledHasSignalUnits =
      let
        names = builtins.attrNames disabledSystem.config.systemd.user.services;
      in
      if builtins.elem "spaces-signal-cli" names then "yes" else "no";
  }
  ''
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # ── 1. daemon unit shape ─────────────────────────────────────────
    case "$execStart" in
      *"signal-cli daemon"*) ;;
      *) fail "ExecStart does not invoke 'signal-cli daemon': $execStart" ;;
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

    # ── 2. bridge (forwarder) unit shape ─────────────────────────────
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

    # ── 3. store dir created unconditionally; NO signal skill farmed ──
    # The bridge writes messages.db here and the integration reads it, so
    # the dir must exist even on hosts that never linked Signal.
    case "$enabledTmpfiles" in
      *"d %h/.local/state/spaces/signal 0700"*) ;;
      *) fail "user-tmpfiles must create %h/.local/state/spaces/signal 0700 unconditionally: $enabledTmpfiles" ;;
    esac
    # The agent-facing signal skill was removed (its surface moved to the
    # integration-signal MCP server); it must never reach the skills-defs farm.
    case "$enabledTmpfiles" in
      *"/skills-defs/signal "*) fail "signal skill still reaches pi-chat skills-defs — it was removed in the integration migration." ;;
      *) ;;
    esac

    # ── 4. ConditionPathExistsGlob gates both units until first link ──
    # Without this the daemon spins a JVM at every login for nothing on
    # fresh systems; with it, login does not start signal-cli until an
    # account dir appears.
    expectedGlob='%h/.local/share/signal-cli/data/*.d'
    [ "$serviceCondition" = "$expectedGlob" ] \
      || fail "daemon ConditionPathExistsGlob must be '$expectedGlob', got '$serviceCondition'"
    [ "$bridgeCondition" = "$expectedGlob" ] \
      || fail "bridge ConditionPathExistsGlob must be '$expectedGlob', got '$bridgeCondition'"

    # ── 5. path-unit auto-starts the daemon on first link; bridge follows ─
    [ "$pathExistsGlob" = "$expectedGlob" ] \
      || fail "path-unit PathExistsGlob must be '$expectedGlob', got '$pathExistsGlob'"
    [ "$pathUnitTarget" = "spaces-signal-cli.service" ] \
      || fail "path-unit must target spaces-signal-cli.service, got '$pathUnitTarget'"
    case " $pathUnitWantedBy " in
      *" default.target "*) ;;
      *) fail "path-unit must be wantedBy=default.target so login arms it, got '$pathUnitWantedBy'" ;;
    esac
    case " $bridgeWantedBy " in
      *" spaces-signal-cli.service "*) ;;
      *) fail "bridge must be wantedBy=spaces-signal-cli.service (so path-activation propagates), got '$bridgeWantedBy'" ;;
    esac

    # ── 6. opt-out strips every spaces-signal-* user unit ────────────
    [ "$disabledHasSignalUnits" = "no" ] \
      || fail "spaces-signal-cli unit still declared after explicit enable = false"

    # ── 7. spaces-signal without pi-chat must fail eval ──────────────
    if [ "$brokenSucceeded" = "yes" ]; then
      fail "spaces-signal evaluated cleanly without pi-chat; the assertion is missing or stopped catching this combo."
    fi

    echo "OK"
    touch "$out"
  ''
