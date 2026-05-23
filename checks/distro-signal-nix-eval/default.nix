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
#
# Pure nix eval + jq. ~3-5s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  baseModules = [
    inputs.self.nixosModules.noctalia-bar
    inputs.self.nixosModules.signal-cli
    {
      nixpkgs.hostPlatform = "x86_64-linux";
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      boot.loader.grub.enable = false;
      system.stateVersion = "26.05";
    }
  ];

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

  # No noctalia-bar / pi-chat in the import chain — distro-signal
  # alone should trip its own assertion.
  brokenSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.signal-cli
      {
        nixpkgs.hostPlatform = "x86_64-linux";
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
  pichatConfig = enabledSystem.config.environment.etc."distro/pi-chat.json".source;
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
    brokenSucceeded = if brokenAttempt.success then "yes" else "no";
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
      | any(.source == "%t/signal-cli/socket" and .mode == "rw" and .optional == true)
    ' "$pichatConfig" >/dev/null \
      || fail "signal-cli socket not in sandboxBinds: $binds"

    jq -e '
      .sandboxBinds
      | any(.source == "%h/.local/state/distro/signal" and .mode == "rw" and .optional == false)
    ' "$pichatConfig" >/dev/null \
      || fail "signal store dir not in sandboxBinds: $binds"

    jq -e '
      .sandboxBinds
      | any(.source == "%h/.local/share/signal-cli/attachments" and .mode == "ro" and .optional == true)
    ' "$pichatConfig" >/dev/null \
      || fail "signal-cli attachments dir not in sandboxBinds: $binds"

    # ── 3. distro-signal without pi-chat must fail eval ──────────────
    if [ "$brokenSucceeded" = "yes" ]; then
      fail "distro-signal evaluated cleanly without pi-chat; the assertion is missing or stopped catching this combo."
    fi

    echo "OK"
    touch "$out"
  ''
