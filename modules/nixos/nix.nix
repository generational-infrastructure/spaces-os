# Nix daemon defaults: flake-ready, resilient during builds, and de-prioritised
# so builds never starve the machine's real work. This is the single place the
# base layer configures the daemon (daemon scheduling policy lives in the
# profile's commonDefaults so it can be redundancy-checked).
{
  lib,
  config,
  pkgs,
  ...
}:
{
  # Latest Nix, no imperative channels (flakes only).
  nix.package = lib.mkDefault pkgs.nixVersions.latest;
  nix.channel.enable = lib.mkDefault false;

  # Additive feature list — consumers concatenate more, or `mkForce` to replace.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
    "auto-allocate-uids"
    "cgroups"
    "fetch-closure"
    "recursive-nix"
    "configurable-impure-env"
  ]
  ++ lib.optionals (lib.versionAtLeast (lib.versions.majorMinor config.nix.package.version) "2.28") [
    "ca-derivations"
    "impure-derivations"
  ]
  ++ lib.optionals (lib.versionAtLeast (lib.versions.majorMinor config.nix.package.version) "2.29") [
    "blake3-hashes"
  ];
  nix.settings.auto-allocate-uids = lib.mkDefault true;
  nix.settings.system-features = [
    "uid-range"
    "recursive-nix"
  ];
  nix.settings.trusted-users = [ "@wheel" ];

  # Build resilience: auto-GC to never wedge /nix/store, fetch from caches, fail
  # fast, keep more failure context, fall back to building on substituter misses.
  nix.settings.min-free = lib.mkDefault (512 * 1024 * 1024);
  nix.settings.max-free = lib.mkDefault (3000 * 1024 * 1024);
  nix.settings.connect-timeout = lib.mkDefault 5;
  nix.settings.log-lines = lib.mkDefault 25;
  nix.settings.builders-use-substitutes = lib.mkDefault true;
  nix.settings.fallback = lib.mkDefault true;

  nix.optimise.automatic = lib.mkDefault (!config.boot.isContainer);

  # Keep GC and the daemon out of the way of interactive work.
  systemd.services.nix-gc.serviceConfig = {
    CPUSchedulingPolicy = "batch";
    IOSchedulingClass = "idle";
    IOSchedulingPriority = 7;
  };
  systemd.services.nix-daemon.serviceConfig.OOMScoreAdjust = lib.mkDefault 250;
}
