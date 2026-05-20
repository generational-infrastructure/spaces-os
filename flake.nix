{
  description = "distro";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    # Tracks pinpox/opencrow#67 (model listing + switching). Repin to a
    # tagged release once the PR lands; the chat plugin's model dropdown
    # depends on the list-models / set-model wire protocol it adds.
    opencrow.url = "github:generational-infrastructure/opencrow";
    opencrow.inputs.nixpkgs.follows = "nixpkgs";
    opencrow.inputs.treefmt-nix.follows = "treefmt-nix";
    noctalia-shell.url = "github:noctalia-dev/noctalia-shell/v4.7.7";
    noctalia-shell.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.inputs.treefmt-nix.follows = "treefmt-nix";
    voxtype.url = "github:peteonrails/voxtype";
    voxtype.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      base = inputs.blueprint {
        inherit inputs;
        systems = [ "x86_64-linux" ];
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

      debugSystems = [ "x86_64-linux" ];

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
      # get pulled into `nix flake check`. Build with
      #   nix build .#iso.x86_64-linux.installer
      iso = lib.genAttrs debugSystems (_system: {
        installer = base.nixosConfigurations.installer.config.system.build.isoImage;
      });
      overlays = {
        noctalia = import ./overlays/noctalia.nix { flake = base; };
        default = import ./overlays/noctalia.nix { flake = base; };
      };
    };
}
