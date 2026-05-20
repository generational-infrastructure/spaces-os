# Flake-level helpers exported as `distro.lib.<name>`.
#
# Blueprint auto-imports `lib/default.nix` with specialArgs
# `{ inputs, flake, ... }` and publishes the result as `flake.lib`.
{ inputs, flake, ... }:
{
  # Filtered store-path snapshot of the distro flake source.
  #
  # Used as `inputs.distro.url = "path:<distroSrc>"` in the wrapper flake
  # the Calamares installer generates, and as `isoImage.storeContents` /
  # `environment.etc."installer-store-paths"` so installs resolve offline.
  #
  # Excludes top-level dirs irrelevant to the installed system so edits to
  # tests, local notes, or VCS metadata don't trigger a calamares rebuild.
  distroSrc =
    let
      inherit (inputs.nixpkgs) lib;
      excludedTopLevel = [
        ".direnv"
        ".envrc"
        ".git"
        ".gitignore"
        ".jj"
        ".ruff_cache"
        "LICENSE"
        "README.md"
        "checks"
        "debug"
        "devshell.nix"
        "formatter.nix"
        "local"
        "result"
        "scripts"
        "treefmt.nix"
      ];
    in
    builtins.path {
      name = "distro-flake-src";
      path = flake.outPath;
      filter =
        path: _type:
        let
          rel = lib.removePrefix "${toString flake.outPath}/" (toString path);
          top = builtins.head (lib.splitString "/" rel);
        in
        # First clause covers the root directory itself, where the
        # `removePrefix` is a no-op (rel still equals the absolute path).
        rel == toString path || !(builtins.elem top excludedTopLevel);
    };

  # Build a NixOS system pre-wired with the distro module.
  #
  # Consumers (e.g. the Calamares-generated installed flake) only have to
  # supply hostName + host-specific modules; mkSystem injects:
  #   - nixosModules.distro
  #   - specialArgs.inputs = distro flake's own inputs (so distro modules
  #     can resolve `inputs.noctalia-shell`, …)
  #   - specialArgs.flake  = the distro flake itself
  #   - nixpkgs.hostPlatform
  #   - networking.hostName
  mkSystem =
    {
      system,
      hostName,
      modules ? [ ],
    }:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs hostName;
        flake = inputs.self or flake;
      };
      modules = [
        flake.nixosModules.distro
        {
          nixpkgs.hostPlatform = system;
          networking.hostName = hostName;
        }
      ]
      ++ modules;
    };

  # Apply distro's plugins-autoload patch to an arbitrary noctalia-shell
  # derivation. Consumers who already pin their own `noctalia-shell` input
  # (e.g. via home-manager) can wrap it without taking distro's
  # `nixosModules.noctalia` module wholesale:
  #
  #   noctalia-shell = inputs.distro.lib.patchNoctaliaShell
  #     inputs.noctalia.packages.${system}.default;
  patchNoctaliaShell =
    pkg:
    let
      inherit (inputs.nixpkgs) lib;
    in
    # Idempotent: callers may layer the patch via both
    # `nixpkgs.overlays = [ distro.overlays.noctalia ]` (system-wide) and
    # via `pkgs.extend flake.overlays.noctalia` inside distro's
    # noctalia.nix module (per-module shadowing). Without this guard the
    # patch ends up in `patches` twice and patchPhase aborts with
    # "Reversed (or previously applied) patch detected".
    if pkg.passthru.patchedByDistro or false then
      pkg
    else
      (pkg.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (lib.cleanSource ../patches/noctalia-shell-plugin-autoload.patch)
        ];
        postPatch = (old.postPatch or "") + ''
          cp ${lib.cleanSource ../patches/PluginAutoload.qml} \
             Services/Noctalia/PluginAutoload.qml
        '';
        passthru = (old.passthru or { }) // {
          patchedByDistro = true;
        };
      }));
}
