# Vendored + pruned fork of numtide/blueprint's lib/default.nix (upstream rev
# 56131e8628f173d24a27f6d27c0215eff57e40dd). Reasons: drop the flake input,
# strip what spaces doesn't use (darwin / system-manager / rpi / robotnix /
# nix-on-droid, standalone home-manager, TOML devshells, templates,
# legacyPackages), and fix the eager `checks` construction (see that output).
#
# Dir conventions, all we use:
#   lib/            -> flake.lib          (also re-exported via __functor)
#   modules/<cat>/  -> flake.<cat>Modules (nixos, home)
#   packages/       -> flake.packages
#   hosts/          -> flake.nixosConfigurations   (default.nix or configuration.nix)
#   devshells/, devshell.nix -> flake.devShells
#   formatter.nix   -> flake.formatter
#   checks/         -> flake.checks
{ inputs, ... }:
let
  bpInputs = inputs;
  inherit (bpInputs) nixpkgs;
  inherit (nixpkgs) lib;
in
rec {
  # A generator for the top-level attributes of the flake.
  #
  # Designed to work with https://github.com/nix-systems
  mkEachSystem =
    {
      inputs,
      flake,
      systems,
      nixpkgs,
      # We need to treat the packages that are being defined in self differently,
      # since otherwise we trigger infinite recursion when perSystem is defined in
      # terms of the packages defined by self, and self uses perSystem to define
      # its packages.
      # We run into the infrec when trying to filter out packages based on their
      # meta attributes, since that actually requires evaluating the package's derivation
      # and can then in turn change the value of perSystem (by removing packages),
      # which then requires to evaluate the package again, and so on and so forth.
      # To break this cycle, we define perSystem in terms of the filesystem hierarchy,
      # and not based on self.packages, and we don't apply any filtering based on
      # meta attributes yet.
      # The actual self.packages, can then be the filtered set of packages.
      unfilteredPackages,
    }:
    let
      # Memoize the args per system
      systemArgs = lib.genAttrs systems (
        system:
        let
          perSystem = mkPerSystem {
            inherit inputs system;
            selfPackages = unfilteredPackages.${system};
          };

          # Handle nixpkgs specially.
          pkgs =
            if (nixpkgs.config or { }) == { } && (nixpkgs.overlays or [ ]) == [ ] then
              perSystem.nixpkgs
            else
              import inputs.nixpkgs {
                inherit system;
                config = nixpkgs.config or { };
                overlays = nixpkgs.overlays or [ ];
              };
        in
        lib.makeScope lib.callPackageWith (_: {
          inherit
            inputs
            perSystem
            flake
            pkgs
            system
            ;
        })
      );

      eachSystem = f: lib.genAttrs systems (system: f systemArgs.${system});
    in
    {
      inherit systemArgs eachSystem;
    };

  optionalPathAttrs = path: f: lib.optionalAttrs (builtins.pathExists path) (f path);

  # Imports the path and pass the `args` to it if it exists, otherwise, return an empty attrset.
  tryImport = path: args: optionalPathAttrs path (path: import path args);

  importDir =
    path: fn:
    let
      entries = builtins.readDir path;

      # Get paths to directories
      onlyDirs = lib.filterAttrs (_name: type: type == "directory") entries;
      dirPaths = lib.mapAttrs (name: type: {
        path = path + "/${name}";
        inherit type;
      }) onlyDirs;

      # Get paths to nix files, where the name is the basename of the file without the .nix extension
      nixPaths = builtins.removeAttrs (lib.mapAttrs' (
        name: type:
        let
          nixName = builtins.match "(.*)\\.nix" name;
        in
        {
          name = if type == "directory" || nixName == null then "__junk" else (builtins.head nixName);
          value = {
            path = path + "/${name}";
            inherit type;
          };
        }
      ) entries) [ "__junk" ];

      # Have the nix files take precedence over the directories
      combined = dirPaths // nixPaths;
    in
    lib.optionalAttrs (builtins.pathExists path) (fn combined);

  entriesPath = lib.mapAttrs (_name: { path, type }: path);

  # Prefixes all the keys of an attrset with the given prefix
  withPrefix =
    prefix:
    lib.mapAttrs' (
      name: value: {
        name = "${prefix}${name}";
        inherit value;
      }
    );

  # Resolve perSystem.<input> for every flake input. For inputs.self,
  # `selfPackages` is merged instead of `self.packages.${system}` so the
  # caller can break the packages → filterPlatforms → perSystem.self
  # → packages cycle (see the comment on `unfilteredPackages` in
  # mkEachSystem) and, in the overlay case, point intra-set references
  # at the set built against the caller's nixpkgs.
  mkPerSystem =
    {
      inputs,
      system,
      selfPackages,
    }:
    lib.mapAttrs (
      name: input:
      (input.legacyPackages.${system} or { })
      // (if name == "self" then selfPackages else input.packages.${system} or { })
    ) inputs;

  filterPlatforms =
    system: attrs:
    lib.filterAttrs (
      _: x:
      if (x.meta.platforms or [ ]) == [ ] then
        true # keep every package that has no meta.platforms
      else
        lib.elem system x.meta.platforms
    ) attrs;

  mkBlueprint' =
    {
      inputs,
      nixpkgs,
      flake,
      src,
      systems,
    }:
    let
      specialArgs = {
        inherit inputs flake;
        self = throw "self was renamed to flake";
      };

      inherit
        (mkEachSystem {
          inherit
            inputs
            flake
            nixpkgs
            systems
            unfilteredPackages
            ;
        })
        eachSystem
        systemArgs
        ;

      # Adds the perSystem argument to the NixOS modules
      perSystemArgsModule = system: {
        _module.args.perSystem = systemArgs.${system}.perSystem;
      };

      perSystemModule =
        { config, lib, ... }:
        {
          imports = [ (perSystemArgsModule config.nixpkgs.hostPlatform.system) ];
        };

      # Share the per-system pkgs blueprint already instantiated (with the
      # configured nixpkgs.config/overlays applied) instead of having the
      # NixOS module system import nixpkgs a second time with the same
      # settings.
      #
      # Only injected when blueprint actually has config/overlays to
      # propagate; otherwise hosts keep full control of their nixpkgs.*
      # options. mkDefault so a host can still set its own nixpkgs.pkgs.
      nixpkgsConfigModule =
        if (nixpkgs.config or { }) == { } && (nixpkgs.overlays or [ ]) == [ ] then
          { }
        else
          (
            { config, lib, ... }:
            {
              nixpkgs.pkgs = lib.mkDefault systemArgs.${config.nixpkgs.hostPlatform.system}.pkgs;
            }
          );

      hosts = importDir (src + "/hosts") (
        entries:
        let
          loadDefaultFn = { class, value }@inputs: inputs;

          loadDefault = hostName: path: loadDefaultFn (import path { inherit flake inputs hostName; });

          loadNixOS = hostName: path: {
            class = "nixos";
            value = inputs.nixpkgs.lib.nixosSystem {
              modules = [
                nixpkgsConfigModule
                perSystemModule
                path
              ];
              specialArgs = specialArgs // {
                inherit hostName;
              };
            };
          };

          loadHost =
            name:
            { path, type }:
            if builtins.pathExists (path + "/default.nix") then
              loadDefault name (path + "/default.nix")
            else if builtins.pathExists (path + "/configuration.nix") then
              loadNixOS name (path + "/configuration.nix")
            else
              throw "host '${name}' does not have a default.nix or configuration.nix";
        in
        lib.mapAttrs loadHost entries
      );

      hostsByCategory = lib.mapAttrs (_: hosts: lib.listToAttrs hosts) (
        lib.groupBy (
          x:
          if x.value.class == "nixos" then
            "nixosConfigurations"
          else
            throw "host '${x.name}' of class '${x.value.class or "unknown"}' not supported"
        ) (lib.attrsToList hosts)
      );

      publisherArgs = {
        inherit flake inputs;
      };

      expectsPublisherArgs =
        module:
        builtins.isFunction module
        && builtins.all (arg: builtins.elem arg (builtins.attrNames publisherArgs)) (
          builtins.attrNames (builtins.functionArgs module)
        );

      # Checks if the given module is wrapped in a function accepting one or more of publisherArgs.
      # If so, call that function. This allows modules to refer to the flake where it is
      # defined, while the module arguments "flake", "inputs" and "perSystem" refer to the flake
      # where the module is consumed.
      injectPublisherArgs =
        modulePath:
        let
          module = import modulePath;
        in
        if expectsPublisherArgs module then
          lib.setDefaultModuleLocation modulePath (module publisherArgs)
        else
          modulePath;

      modules =
        let
          path = src + "/modules";
          moduleDirs = builtins.attrNames (
            lib.filterAttrs (_name: value: value == "directory") (builtins.readDir path)
          );
        in
        lib.optionalAttrs (builtins.pathExists path) (
          lib.genAttrs moduleDirs (
            name: lib.mapAttrs (_name: injectPublisherArgs) (importDir (path + "/${name}") entriesPath)
          )
        );

      packageEntries =
        (optionalPathAttrs (src + "/packages") (path: importDir path lib.id))
        // (optionalPathAttrs (src + "/package.nix") (path: {
          default = {
            inherit path;
          };
        }))
        // (optionalPathAttrs (src + "/formatter.nix") (path: {
          formatter = {
            inherit path;
          };
        }));

      # See the comment in mkEachSystem
      unfilteredPackages = lib.traceIf (builtins.pathExists (
        src + "/pkgs"
      )) "blueprint: the /pkgs folder is now /packages" (eachSystem ({ pkgs, ... }: mkPackagesFor pkgs));

      # Load the packages/ tree against a given nixpkgs instance.
      # Packages get the same scope arguments as via systemArgs (pkgs,
      # flake, inputs, system, perSystem, pname). perSystem.self resolves
      # within this scope so intra-set references stay consistent with
      # the supplied nixpkgs.
      #
      # Used internally for packages.<system> (with blueprint's own
      # pkgs) and exposed so consumers can build an overlay that uses
      # their pkgs instead.
      mkPackagesFor =
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          scope = lib.makeScope lib.callPackageWith (self: {
            inherit
              inputs
              flake
              pkgs
              system
              ;
            perSystem = mkPerSystem {
              inherit inputs system;
              selfPackages = self.packageSet;
            };
            # NB: lib.makeScope reserves `packages` for its generator
            # function, so the result lives under a different name.
            packageSet = lib.mapAttrs (
              pname: { path, ... }: self.newScope { inherit pname; } path { }
            ) packageEntries;
          });
        in
        scope.packageSet;
    in
    {
      formatter = eachSystem (
        { pkgs, perSystem, ... }:
        perSystem.self.formatter or pkgs.nixfmt-tree
      );

      lib = tryImport (src + "/lib") specialArgs;

      # expose the functor to the top-level
      __functor = x: inputs.self.lib.__functor x;

      devShells =
        let
          namedNix = optionalPathAttrs (src + "/devshells") (
            path:
            (importDir path (
              entries:
              eachSystem (
                { newScope, ... }:
                lib.mapAttrs (pname: { path, type }: newScope { inherit pname; } path { }) (
                  lib.filterAttrs (
                    _name:
                    { path, type }:
                    type == "regular" || (type == "directory" && lib.pathExists "${path}/default.nix")
                  ) entries
                )
              )
            ))
          );

          defaultNix = optionalPathAttrs (src + "/devshell.nix") (
            path:
            eachSystem (
              { newScope, ... }:
              {
                default = newScope { pname = "default"; } path { };
              }
            )
          );

          merge =
            prev: item:
            let
              systems = lib.attrNames (prev // item);
              mergeSystem = system: { ${system} = (prev.${system} or { }) // (item.${system} or { }); };
              mergedSystems = builtins.map mergeSystem systems;
            in
            lib.mergeAttrsList mergedSystems;
        in
        lib.foldl merge { } [
          namedNix
          defaultNix
        ];

      # See the comment in mkEachSystem
      packages = lib.mapAttrs filterPlatforms unfilteredPackages;

      inherit mkPackagesFor;

      nixosConfigurations = lib.mapAttrs (_: x: x.value) (hostsByCategory.nixosConfigurations or { });

      inherit modules;

      homeModules = modules.home or { };
      nixosModules = modules.nixos or { };

      # Checks keyset, kept lazy on the primary platform. On x86_64-linux the
      # keys come from readDir, so listing or building one check never forces
      # the others' derivations or every package's `meta` — that's the whole
      # point of this fork (upstream's filterPlatforms did that on every system,
      # ~16s cold here).
      #
      # Other systems (aarch64) still run filterPlatforms: CI builds every key,
      # so an x86_64-only package or nixosTest must not be offered as an aarch64
      # build (it would just fail there). x86_64 is primary and every check
      # builds there, so its set needs no filter; the meta forcing lands only on
      # the non-interactive path.
      #
      # Still not folded in (would re-force every package): package
      # passthru.tests — wire such a test as an explicit /checks entry. The
      # nixos- filter below is the one bit that always evaluates hosts (~1.5s).
      checks = eachSystem (
        { system, ... }:
        let
          all = lib.mergeAttrsList [
            # Every package by name (formatter has its own output, not a check).
            (withPrefix "pkgs-" (builtins.removeAttrs (unfilteredPackages.${system} or { }) [ "formatter" ]))
            # Devshells.
            (withPrefix "devshell-" (inputs.self.devShells.${system} or { }))
            # Host toplevels for this system.
            (withPrefix "nixos-" (
              lib.mapAttrs (_: x: x.config.system.build.toplevel) (
                lib.filterAttrs (_: x: x.pkgs.stdenv.hostPlatform.system == system) (
                  inputs.self.nixosConfigurations or { }
                )
              )
            ))
            # The /checks folder — keys from importDir (readDir).
            (optionalPathAttrs (src + "/checks") (
              path:
              importDir path (
                lib.mapAttrs (pname: { type, path }: import path (systemArgs.${system} // { inherit pname; }))
              )
            ))
          ];
        in
        if system == "x86_64-linux" then all else filterPlatforms system all
      );
    };

  # Create a new flake blueprint
  mkBlueprint =
    {
      # Pass the flake inputs to blueprint
      inputs,
      # Load the blueprint from this path
      prefix ? null,
      # Used to configure nixpkgs
      nixpkgs ? {
        config = { };
      },
      # The systems to generate the flake for
      systems ? inputs.systems or bpInputs.systems,
    }:
    mkBlueprint' {
      inputs = bpInputs // inputs;
      flake = inputs.self;

      inherit nixpkgs;

      src =
        if prefix == null then
          inputs.self
        else if builtins.isPath prefix then
          prefix
        else if builtins.isString prefix then
          "${inputs.self}/${prefix}"
        else
          throw "${builtins.typeOf prefix} is not supported for the prefix";

      # Make compatible with github:nix-systems/default
      systems = if lib.isList systems then systems else import systems;
    };

  # Make this callable
  __functor = _: mkBlueprint;
}
