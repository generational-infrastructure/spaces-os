# Cheap nix-eval contract for the spaces-signal NixOS module.
#
# spaces-signal is a pure daemon → messages.db forwarder: signal-cli runs as a
# JSON-RPC daemon and spaces-signal-bridge subscribes and persists envelopes
# into ~/.local/state/spaces/signal/messages.db, which the integration-signal
# MCP server reads.
#
# Lifecycle is now GUI-only: whether the daemon + bridge run is decided by
# enabling/disabling the Signal integration through the panel/broker, NOT by
# nix. So the daemon + bridge:
#   - carry NO wantedBy (no nix-driven autostart at login);
#   - carry NO ConditionPathExistsGlob (the daemon must run UNLINKED so the
#     panel setup flow's startLink JSON-RPC works before any device exists);
#   - are pulled in by the Signal integration socket (Wants=/After=) and torn
#     down with it (PartOf=spaces-integration-signal.socket, injected by the
#     spaces-integrations module from the signal manifest's extraServices);
# and the old spaces-signal-link path unit is GONE.
#
# Verifies:
#   1. daemon unit shape (ExecStart daemon args; RuntimeDirectory + mode; Type;
#      Restart) and it carries NO wantedBy / NO Condition.
#   2. bridge forwarder unit runs the bridge binary, requires/orders after the
#      daemon, restarts, and carries NO wantedBy / NO Condition.
#   3. both units carry PartOf=spaces-integration-signal.socket (GUI lifecycle).
#   4. the spaces-signal-link path unit no longer exists.
#   5. the store dir is created unconditionally by user-tmpfiles, and NO signal
#      skill reaches the pi-chat skills-defs farm (the skill is gone).
#   6. enabling spaces-signal without pi-chat trips the module assertion.
#   7. an explicit enable = false strips every spaces-signal-* user unit.
#
# Pure nix eval. ~3-5s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  baseModules = [
    # spaces -> pi-chat imports the signal-cli AND spaces-integrations modules
    # transitively, so the eval here exercises the same import graph (and the
    # PartOf injection) spaces users get.
    inputs.self.nixosModules.spaces
  ];

  mkSystem =
    extra:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = extra;
    };

  # Default deployment shape: spaces (auto-enables pi-chat, which enables
  # spaces-integrations with the default signal integration) plus an explicit
  # `enable = true` on spaces-signal.
  enabledSystem = mkSystem (
    baseModules
    ++ [
      {
        networking.hostName = "signal-enabled";
        services.spaces-signal.enable = true;
      }
    ]
  );

  # Opt-out path: explicit `enable = false`. spaces-integrations is disabled too
  # so its extraServices PartOf injection can't leave a phantom spaces-signal-cli
  # behind — this isolates spaces-signal's own mkIf, which must leave NO
  # spaces-signal-* user units.
  disabledSystem = mkSystem (
    baseModules
    ++ [
      {
        networking.hostName = "signal-disabled";
        services.spaces-signal.enable = false;
        services.spaces-integrations.enable = false;
      }
    ]
  );

  # No spaces / pi-chat in the import chain — spaces-signal alone should trip
  # its own assertion.
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
in
pkgs.runCommand "spaces-signal-nix-eval-test"
  {
    execStart = service.serviceConfig.ExecStart;
    runtimeDir = service.serviceConfig.RuntimeDirectory or "";
    runtimeDirMode = service.serviceConfig.RuntimeDirectoryMode or "";
    serviceType = service.serviceConfig.Type or "";
    restart = service.serviceConfig.Restart or "";
    wantedBy = lib.concatStringsSep " " (service.wantedBy or [ ]);
    partOf = lib.concatStringsSep " " (lib.toList (service.unitConfig.PartOf or [ ]));
    condition = lib.concatStringsSep " " (
      lib.toList (service.unitConfig.ConditionPathExistsGlob or [ ])
    );
    bridgeExecStart = bridge.serviceConfig.ExecStart;
    bridgeRequires = lib.concatStringsSep " " (bridge.requires or [ ]);
    bridgeAfter = lib.concatStringsSep " " (bridge.after or [ ]);
    bridgeRestart = bridge.serviceConfig.Restart or "";
    bridgeWantedBy = lib.concatStringsSep " " (bridge.wantedBy or [ ]);
    bridgePartOf = lib.concatStringsSep " " (lib.toList (bridge.unitConfig.PartOf or [ ]));
    bridgeCondition = lib.concatStringsSep " " (
      lib.toList (bridge.unitConfig.ConditionPathExistsGlob or [ ])
    );
    brokenSucceeded = if brokenAttempt.success then "yes" else "no";
    enabledTmpfiles = lib.concatStringsSep "\n" enabledSystem.config.systemd.user.tmpfiles.rules;
    # The old path-activation unit must no longer exist anywhere.
    hasPathUnit =
      if builtins.hasAttr "spaces-signal-link" (enabledSystem.config.systemd.user.paths or { }) then
        "yes"
      else
        "no";
    # When the user opts out, spaces-signal-cli must NOT be declared at all
    # (not "declared but disabled"). Empty string = absent.
    disabledHasSignalUnits =
      let
        names = builtins.attrNames disabledSystem.config.systemd.user.services;
      in
      if builtins.elem "spaces-signal-cli" names then "yes" else "no";
    # The finishLink linking bug: signal-cli 0.14.2–0.14.4 daemons break
    # finishLink under an active receive subscription (subscribeReceive
    # collects handlers into an immutable .toList(), so onManagerAdded's
    # handlers.add() throws UnsupportedOperationException -> JSON-RPC -32603
    # -> the panel's GUI QR link flow dies with "Setup failed"). Fixed in
    # 0.14.5 (Collectors.toCollection(ArrayList::new)), so the module's
    # package MUST be >= 0.14.5.
    signalPkgVersion = enabledSystem.config.services.spaces-signal.package.version;
    signalPkgVersionOk =
      if lib.versionAtLeast enabledSystem.config.services.spaces-signal.package.version "0.14.5" then
        "yes"
      else
        "no";
  }
  ''
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # ── 1. daemon unit shape + GUI-only lifecycle ────────────────────
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

    # GUI owns the lifecycle: no nix autostart, no link-gate condition.
    [ -z "$wantedBy" ]  || fail "daemon must carry NO wantedBy (GUI-only lifecycle), got '$wantedBy'"
    [ -z "$condition" ] || fail "daemon must carry NO ConditionPathExistsGlob (must run unlinked), got '$condition'"

    # ── 2. bridge (forwarder) unit shape + GUI-only lifecycle ────────
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
    [ -z "$bridgeWantedBy" ]  || fail "bridge must carry NO wantedBy (GUI-only lifecycle), got '$bridgeWantedBy'"
    [ -z "$bridgeCondition" ] || fail "bridge must carry NO ConditionPathExistsGlob, got '$bridgeCondition'"

    # ── 3. both units bound to the Signal integration socket ─────────
    # PartOf=spaces-integration-signal.socket, injected by the
    # spaces-integrations module from the signal manifest's extraServices, so a
    # GUI disable (socket stop) tears the daemon + bridge down too.
    partof='spaces-integration-signal.socket'
    case " $partOf " in
      *" $partof "*) ;;
      *) fail "daemon must be PartOf=$partof (GUI lifecycle), got '$partOf'" ;;
    esac
    case " $bridgePartOf " in
      *" $partof "*) ;;
      *) fail "bridge must be PartOf=$partof (GUI lifecycle), got '$bridgePartOf'" ;;
    esac

    # ── 4. the old path-activation unit is gone ──────────────────────
    [ "$hasPathUnit" = "no" ] \
      || fail "spaces-signal-link path unit still exists; linking moved to the GUI setup flow."

    # ── 5. store dir created unconditionally; NO signal skill farmed ──
    # The bridge writes messages.db here and the integration reads it, so the
    # dir must exist even on hosts that never linked Signal.
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

    # ── 6. opt-out strips every spaces-signal-* user unit ────────────
    [ "$disabledHasSignalUnits" = "no" ] \
      || fail "spaces-signal-cli unit still declared after explicit enable = false"

    # ── 7. spaces-signal without pi-chat must fail eval ──────────────
    if [ "$brokenSucceeded" = "yes" ]; then
      fail "spaces-signal evaluated cleanly without pi-chat; the assertion is missing or stopped catching this combo."
    fi

    # ── 8. signal-cli package is >= 0.14.5 (GUI QR linking bug) ──────
    # 0.14.2–0.14.4 daemons throw UnsupportedOperationException from
    # finishLink under the bridge's active receive subscription, so the
    # panel's QR link flow fails. The module default must pin >= 0.14.5.
    [ "$signalPkgVersionOk" = "yes" ] \
      || fail "services.spaces-signal.package must be signal-cli >= 0.14.5 (GUI QR linking finishLink bug), got $signalPkgVersion"

    echo "OK"
    touch "$out"
  ''
