{
  description = "distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";
    blueprint.inputs.systems.follows = "systems";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    noctalia-shell.url = "github:noctalia-dev/noctalia-shell/v4.7.7";
    noctalia-shell.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.inputs.treefmt-nix.follows = "treefmt-nix";
    llm-agents.inputs.blueprint.follows = "blueprint";
    llm-agents.inputs.systems.follows = "systems";
    voxtype.url = "github:peteonrails/voxtype";
    voxtype.inputs.nixpkgs.follows = "nixpkgs";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      base = inputs.blueprint {
        inherit inputs;
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        nixpkgs.config.allowUnfree = true;
      };

      # Heavy / VM-driven installer tests live under ./debug and are
      # exposed as `debug.<system>.<name>` so they don't get pulled in
      # by `nix flake check`. Build individually, e.g.
      #   nix build .#debug.x86_64-linux.installer-loadmodule
      debugTests = [
        "installer-config-gen"
        "installer-gui-end-to-end"
        "installer-loadmodule"
        "installer-target-session"
      ];

      # Debug tests are x86_64-only: the GUI-end-to-end test spawns
      # qemu-system-x86_64 and the loadmodule probes assume the x86
      # toplevel from `nixosConfigurations.installer-target`. Per-arch
      # variants can come later if/when there's demand.
      debugSystems = [ "x86_64-linux" ];

      # ISO outputs are per-architecture: each system points at the
      # matching installer host. Keep this list in sync with the
      # `installer-<arch>` host dirs under ./hosts.
      isoSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      installerHostFor = system: if system == "aarch64-linux" then "installer-aarch64" else "installer";

      mkDebug =
        system:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          tests = lib.genAttrs debugTests (
            name:
            let
              # Each test may be either `debug/<name>.nix` or
              # `debug/<name>/default.nix` — pick the directory form
              # when present so per-test fixtures (helper packages,
              # YAML inputs, etc.) can live alongside their consumer.
              dir = ./debug + "/${name}";
              file = ./debug + "/${name}.nix";
              path = if builtins.pathExists (dir + "/default.nix") then dir else file;
            in
            import path {
              inherit pkgs inputs system;
              flake = base;
            }
          );
        in
        tests
        // {
          # Aggregate pulling in every debug derivation. Build with
          #   nix build .#debug.<system>.all
          all =
            (pkgs.linkFarm "debug-all" (
              lib.mapAttrsToList (name: drv: {
                inherit name;
                path = drv;
              }) tests
            )).overrideAttrs
              (_old: {
                __impure = true;
              });
        };
    in
    base
    // {
      debug = lib.genAttrs debugSystems mkDebug;
      # Bootable ISO image, exposed outside `packages` so it doesn't
      # get pulled into `nix flake check`. Per-system: each entry
      # picks the installer host whose hostPlatform matches.
      #   nix build .#iso.x86_64-linux.installer
      #   nix build .#iso.aarch64-linux.installer
      iso = lib.genAttrs isoSystems (system: {
        installer = base.nixosConfigurations.${installerHostFor system}.config.system.build.isoImage;
      });
      overlays = {
        noctalia = import ./overlays/noctalia.nix { flake = base; };
        default = import ./overlays/noctalia.nix { flake = base; };
      };
    };
}
