# Regression: pi-chat's notification-history redirect only works if
# noctalia is launched by the systemd user unit (so the
# `noctalia-shell.service` Environment= lines reach the process).
#
# A historical bug: a downstream config imported `nixosModules.noctalia-plugin`
# (pi-chat + llama-swap) but NOT `nixosModules.noctalia` (the unit + ExecStart).
# noctalia was started by niri's spawn-at-startup, so the redirect never
# reached the running process and the notifications skill always returned
# "(no notifications)". The full-stack VM test in checks/test-machine.nix
# wouldn't catch this — it imports `nixosModules.distro` which pulls in
# both halves and the redirect works there.
#
# Guard rail: the pi-chat module asserts at eval time that
# `systemd.user.services.noctalia-shell.serviceConfig.ExecStart` is
# defined whenever the pi-chat module is enabled. This check exercises
# the broken combo and asserts the eval fails with our message.
{ pkgs, inputs, ... }:
let
  brokenSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.noctalia-plugin
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        networking.hostName = "broken";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
      }
    ];
  };

  fixedSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.noctalia-bar
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        networking.hostName = "fixed";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
      }
    ];
  };

  # tryEval doesn't actually evaluate deeply enough to trip module
  # assertions — we have to force the toplevel derivation. Wrap in
  # builtins.tryEval + builtins.deepSeq so the eval failure surfaces
  # as `success = false` rather than aborting the check.
  brokenAttempt = builtins.tryEval (
    builtins.deepSeq brokenSystem.config.system.build.toplevel.drvPath null
  );

  fixedAttempt = builtins.tryEval (
    builtins.deepSeq fixedSystem.config.system.build.toplevel.drvPath null
  );
in
pkgs.runCommand "pi-chat-notif-assertion-test"
  {
    brokenSucceeded = if brokenAttempt.success then "yes" else "no";
    fixedSucceeded = if fixedAttempt.success then "yes" else "no";
  }
  ''
    set -euo pipefail

    if [ "$brokenSucceeded" = "yes" ]; then
      echo "FAIL: noctalia-plugin without noctalia.nix evaluated cleanly;"
      echo "the pi-chat assertion is missing or stopped catching this combo."
      exit 1
    fi

    if [ "$fixedSucceeded" = "no" ]; then
      echo "FAIL: noctalia-bar (the correct combo) failed to evaluate."
      echo "The assertion is over-fitting and breaking the supported path."
      exit 1
    fi

    echo "OK: broken combo trips the assertion, supported combo evaluates."
    touch "$out"
  ''
