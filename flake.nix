{
  description = "Spaces OS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    # Pinned to the 0.78.x (@earendil-works) line the deployed executors run.
    # (HEAD of llm-agents.nix needs pnpm_11, absent in our nixpkgs; this rev is
    # the one kiwi deploys.) Bump in lockstep with a nixpkgs that has its pnpm.
    llm-agents.url = "github:numtide/llm-agents.nix/2296793afdc076c2fd495ac21b914c26a9f2bf0e";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.inputs.treefmt-nix.follows = "treefmt-nix";
    llm-agents.inputs.systems.follows = "systems";
    # Fork branch adds the nemotron multilingual streaming ASR engine (reuses
    # the parakeet ONNX feature). Not yet upstream in peteonrails/voxtype.
    voxtype.url = "github:a-kenji/voxtype/ke-init-nemotron-support-streaming";
    voxtype.inputs.nixpkgs.follows = "nixpkgs";
    voxtype.inputs.flake-utils.inputs.systems.follows = "systems";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    systems.url = "github:nix-systems/default";
    # Hermes agent microvms (modules/nixos/hermes). Follows our nixpkgs —
    # viable because the one nixpkgs-coupled upstream package (the desktop
    # renderer, whose electron node-headers FOD hash must match nixpkgs'
    # electron) is vendored with a corrected hash in
    # modules/nixos/hermes/desktop.nix; diff it against upstream's
    # nix/desktop.nix when bumping this input. Tracks the latest stable
    # release tag.
    hermes-agent.url = "github:NousResearch/hermes-agent/v2026.7.20";
    hermes-agent.inputs.nixpkgs.follows = "nixpkgs";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      # Vendored + pruned fork of numtide/blueprint — see lib/flake/default.nix
      # (dropped the input; fixes the eager checks keyset).
      base = (import ./lib/flake { inherit inputs; }) {
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
        "installer-welcome-screenshot"
        "installer-target-session"
      ];

      # Debug tests are x86_64-only: the GUI-end-to-end test spawns
      # qemu-system-x86_64 and the loadmodule probes assume the x86
      # toplevel from `nixosConfigurations.installer-target`. Per-arch
      # variants can come later if/when there's demand.
      debugSystems = [ "x86_64-linux" ];

      # Per-architecture installer host names, published by
      # ./lib/default.nix as the single source of truth shared with
      # the host dirs and modules/nixos/installer-iso.nix.
      inherit (base.lib) installerHosts;

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
      # Bootable ISO image per architecture, exposed outside `packages`
      # so it doesn't get pulled into `nix flake check`. Each entry
      # picks the installer host whose hostPlatform matches.
      #   nix build .#iso.x86_64-linux.installer
      #   nix build .#iso.aarch64-linux.installer
      iso = lib.mapAttrs (_system: hosts: {
        installer = base.nixosConfigurations.${hosts.installer}.config.system.build.isoImage;
      }) installerHosts;

      # Clan service modules. Consumers (e.g. pinpox/nixos) import the
      # spaces-os flake as a clan input and reference services by name:
      #
      #   instances.pi = {
      #     module.input = "spaces";
      #     module.name  = "pi";
      #     roles.executor.machines.kiwi   = { };
      #     roles.executor.machines.traube = { };
      #     roles.client.machines.kiwi     = { };
      #   };
      #
      # The service module captures spaces-os's `self` here so its
      # `nixosModules.pi-sessiond` / `nixosModules.pi-chat` references
      # resolve to spaces-os's pinned modules (and, transitively, its
      # pinned llm-agents pi), independent of which consumer flake
      # evaluates the inventory.
      clan.modules.pi = import ./clan-service-modules/pi { flake-self = inputs.self; };
    };
}
