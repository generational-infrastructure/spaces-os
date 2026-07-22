# Flake-level helpers exported as `spaces.lib.<name>`.
#
# Blueprint auto-imports `lib/default.nix` with specialArgs
# `{ inputs, flake, ... }` and publishes the result as `flake.lib`.
{ inputs, flake, ... }:
let
  # Single source of truth for the per-architecture installer hosts.
  # Everything arch-related derives from this map:
  #   - the `hosts/<name>` blueprint dirs (one-line mkInstallerHost /
  #     mkInstallerTarget calls),
  #   - flake.nix's `iso.<system>` outputs,
  #   - installer-iso.nix's pre-staged installed-system closure.
  installerHosts = {
    "x86_64-linux" = {
      installer = "installer";
      target = "installer-target";
    };
    "aarch64-linux" = {
      installer = "installer-aarch64";
      target = "installer-target-aarch64";
    };
  };
in
{
  inherit installerHosts;

  # Blueprint host body for the bootable graphical installer ISO of
  # the given arch. Host dirs stay one-line calls because blueprint
  # discovers hosts by directory, not by attrset.
  mkInstallerHost = arch: {
    class = "nixos";
    value = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs flake;
      };
      modules = [
        { nixpkgs.hostPlatform = arch; }
        ../modules/nixos/installer-iso.nix
      ];
    };
  };

  # Blueprint host body for the never-booted "installed system" of the
  # given arch — the representative closure installer-iso.nix points
  # `isoImage.storeContents` at so `nixos-install` resolves offline.
  mkInstallerTarget = arch: {
    class = "nixos";
    value = inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs flake;
      };
      modules = [
        { nixpkgs.hostPlatform = arch; }
        inputs.self.nixosModules.spaces
        ../hosts/installer-target/configuration.nix
      ];
    };
  };

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

  # Minimal bootable NixOS eval fixture for the checks/ nix-eval tests.
  #
  # Every cheap nix-eval check wants the same throwaway scaffolding —
  # enough to satisfy the NixOS assertions (a root fs, a bootloader
  # decision, a stateVersion) without pulling in nixosModules.spaces the
  # way mkSystem does, so a single module can be evaluated in isolation.
  # Checks pass only the modules under test (plus any hostName /
  # fixture config as ordinary modules); the audited call sites vary
  # nothing else, so the surface stays exactly { modules, system }.
  #
  # Deliberately NOT delegated to by mkSystem: real hosts must supply
  # their own fileSystems/bootloader, and injecting the tmpfs root here
  # would conflict with (not be overridden by) a host's disk config.
  mkEvalSystem =
    {
      modules ? [ ],
      system ? "x86_64-linux",
    }:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self or flake;
      };
      modules = [
        {
          nixpkgs.hostPlatform = system;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          boot.loader.grub.enable = false;
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    };

  # Fast sibling of mkEvalSystem: nixpkgs.lib.nixos.evalModules instead of
  # nixosSystem, keeping the ~2000-entry module-list out of the fixpoint
  # (~0.3s vs ~1s per eval). The catch: any option a check *reads* must be
  # declared, so baseModules carries the common surface these checks read
  # back. Options a module only *sets* need nothing (_module.check = false).
  # A check reading something rarer (networking.firewall, caddy) passes the
  # declaring module in its own `modules` list.
  mkMinimalEvalSystem =
    {
      modules ? [ ],
      system ? "x86_64-linux",
    }:
    let
      inherit (inputs) nixpkgs;
      inherit (nixpkgs) lib;
      # Mirror flake.nix so unfree packages (voxtype's CUDA path) eval as on a real host.
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      m = p: nixpkgs + ("/nixos/modules/" + p);
      baseModules = [
        (
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            _module.args.utils = import (nixpkgs + "/nixos/lib/utils.nix") { inherit lib config pkgs; };
          }
        )
        (m "system/boot/systemd.nix")
        (m "system/boot/systemd/user.nix")
        (m "system/boot/systemd/tmpfiles.nix")
        (m "misc/assertions.nix")
        # environment.* cluster
        (m "config/system-path.nix")
        (m "system/etc/etc.nix")
        (m "config/system-environment.nix")
        (m "config/shells-environment.nix")
        # users.* cluster: shadow provides users.defaultUserShell, ids the
        # uid/gid maps — both read by users-groups.
        (m "config/users-groups.nix")
        (m "programs/shadow.nix")
        (m "misc/ids.nix")
        # Stubs for options the base modules read but whose owning modules we
        # skip: systemd.nix -> services.openssh.* (sshd-vsock@), users-groups
        # -> boot.initrd.systemd.enable (initrd passwd), tmpfiles ->
        # boot.initrd.systemd.storePaths (initrd tmpfiles.d filtering).
        (
          { lib, ... }:
          {
            options.services.openssh.enable = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            options.services.openssh.package = lib.mkOption {
              default = pkgs.openssh;
              type = lib.types.package;
            };
            options.boot.initrd.systemd.enable = lib.mkOption {
              default = false;
              type = lib.types.bool;
            };
            options.boot.initrd.systemd.storePaths = lib.mkOption {
              default = [ ];
              type = lib.types.listOf lib.types.raw;
            };
          }
        )
        {
          _module.check = false;
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
        }
      ];
    in
    nixpkgs.lib.nixos.evalModules {
      specialArgs = {
        inherit pkgs lib;
        inherit inputs;
        flake = inputs.self or flake;
      };
      modules = baseModules ++ modules;
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
