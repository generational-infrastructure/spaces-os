# Per-launch launcher generator for app-run-flake.
#
# Called via `nix build --file generate-launcher.nix --argstr ...` at
# run time (NOT module-eval time): the CLI synthesises arguments from
# operator-supplied flags, runs this expression, and execs the
# resulting derivation's bin/app-run-flake-launch.
#
# Wires the same launcher logic the static NixOS module uses (via
# `lib/apps-launcher.nix`); the difference is purely whether the
# manifest entry comes from a Nix module's option config or from CLI
# arg parsing.
{
  execPath,
  appId,
  stateDir,
  allow, # comma-separated permission list, e.g. "wayland,network"
  dbusTalk, # newline-separated DBus names; empty means no dbus
  memoryHigh, # empty string defers to the lib default
  tasksMax, # empty string defers to the lib default
  spacesRepo, # path to the spaces repo (for lib/apps-launcher.nix)
}:
let
  pkgs = import <nixpkgs> { };
  inherit (pkgs) lib;

  splitNonEmpty = sep: s: if s == "" then [ ] else lib.filter (x: x != "") (lib.splitString sep s);

  granted = splitNonEmpty "," allow;
  dbusTalkList = splitNonEmpty "\n" dbusTalk;

  # We need the coordinator + wayland-context packages so the
  # launcher's BindPaths / wayland-app-context invocations resolve to
  # the same artefacts the static path uses. Build them from this
  # repo so a `nix-channel`-only system still works.
  appCoordinator = pkgs.callPackage (spacesRepo + "/packages/app-coordinator") { };
  waylandAppContext = pkgs.callPackage (spacesRepo + "/packages/wayland-app-context") { };

  launcherLib = import (spacesRepo + "/lib/apps-launcher.nix") {
    inherit pkgs lib;
    coordinatorPkg = appCoordinator;
    waylandContextPkg = waylandAppContext;
  };

  # Merge CLI-derived overrides with the lib defaults. Empty strings
  # mean "use the default", so we only include them when set.
  resourcesOverrides =
    lib.optionalAttrs (memoryHigh != "") { inherit memoryHigh; }
    // lib.optionalAttrs (tasksMax != "") { tasksMax = lib.toInt tasksMax; };
in
launcherLib.mkLauncher "flake-launch" {
  inherit appId stateDir;
  exec = execPath;
  permissions.granted = granted;
  dbusSession.talk = dbusTalkList;
  resources = resourcesOverrides;
}
