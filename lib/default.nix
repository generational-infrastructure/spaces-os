# Flake-level helpers exported as `spaces.lib.<name>`.
#
# Blueprint auto-imports `lib/default.nix` with specialArgs
# `{ inputs, flake, ... }` and publishes the result as `flake.lib`.
{ inputs, flake, ... }:
{
  # Filtered store-path snapshot of the spaces flake source.
  #
  # Used as `inputs.spaces.url = "path:<spacesSrc>"` in the wrapper flake
  # the Calamares installer generates, and as `isoImage.storeContents` /
  # `environment.etc."installer-store-paths"` so installs resolve offline.
  #
  # Excludes top-level dirs irrelevant to the installed system so edits to
  # tests, local notes, or VCS metadata don't trigger a calamares rebuild.
  spacesSrc =
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
      name = "spaces-flake-src";
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

  # Build a NixOS system pre-wired with the spaces module.
  #
  # Consumers (e.g. the Calamares-generated installed flake) only have to
  # supply hostName + host-specific modules; mkSystem injects:
  #   - nixosModules.spaces
  #   - specialArgs.inputs = spaces flake's own inputs (so spaces modules
  #     can resolve their dependencies)
  #   - specialArgs.flake  = the spaces flake itself
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
        flake.nixosModules.spaces
        {
          nixpkgs.hostPlatform = system;
          networking.hostName = hostName;
        }
      ]
      ++ modules;
    };
}
