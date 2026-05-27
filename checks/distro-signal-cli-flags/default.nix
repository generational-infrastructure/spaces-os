# Guard against signal-cli CLI drift.
#
# The systemd unit in modules/nixos/signal-cli.nix invokes the package
# binary with a specific flag set (`daemon --socket --receive-mode=on-start
# --no-receive-stdout`). If a future signal-cli release renames or
# drops one of those flags, our nix-eval test still passes (it only
# checks the unit spec), and the breakage only surfaces when somebody
# rebuilds and the daemon fails to start on a real system.
#
# This check runs `signal-cli daemon --help` from the *same* derivation
# the NixOS module uses and asserts every flag we depend on is
# documented. Cheap (~3-5s — one JVM startup) and catches the failure
# at flake-check time.
{ pkgs, inputs, ... }:
let
  signalCli =
    (inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = [
        inputs.self.nixosModules.distro
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          networking.hostName = "signal-flags";
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          boot.loader.grub.enable = false;
          system.stateVersion = "26.05";
          services.distro-signal.enable = true;
        }
      ];
    }).config.services.distro-signal.package;
in
pkgs.runCommand "distro-signal-cli-flags-test"
  {
    inherit signalCli;
    # JVM needs a writable home; sandbox has $TMPDIR but no $HOME.
    requiredSystemFeatures = [ ];
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR
    fail() { echo "FAIL: $*" >&2; exit 1; }

    help=$("$signalCli/bin/signal-cli" daemon --help 2>&1 || true)

    for needle in "--socket" "--receive-mode" "on-start" "--no-receive-stdout"; do
      case "$help" in
        *"$needle"*) ;;
        *) fail "signal-cli daemon --help missing '$needle' — CLI drifted; update modules/nixos/signal-cli.nix" ;;
      esac
    done

    echo "OK"
    touch "$out"
  ''
