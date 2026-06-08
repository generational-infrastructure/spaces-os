# Spaces graphical installer ISO.
#
# Imports the upstream NixOS Calamares-GNOME live image and:
#   - shadows `calamares-nixos-extensions` via a nixpkgs overlay so
#     all upstream references resolve to our fork
#     (`calamares-spaces-extensions`), which drops `packagechooser`
#     and emits a flake-based install referencing the spaces flake
#     by its /nix/store path;
#   - bakes that store path into the patched `main.py` at
#     extensions-package build time via the `spacesFlake` arg;
#   - pre-stages the spaces flake source + a representative installed
#     system closure into the ISO's nix store so `nixos-install`
#     resolves everything offline.
#
# The live env is upstream GNOME; the *installed* env is niri (set
# by `nixosModules.spaces` pulled in via the generated flake). That
# mismatch is intentional v1 — the live env doesn't need to match
# what we install.
{
  inputs,
  flake,
  pkgs,
  ...
}:
let
  inherit (inputs.nixpkgs) lib;
  inherit (flake.lib) spacesSrc;

  # Pre-stage the installed-system closure that matches the live
  # medium's arch. Keep this map in sync with the `installer-<arch>`
  # host dirs.
  installerTargetFor =
    {
      "x86_64-linux" = "installer-target";
      "aarch64-linux" = "installer-target-aarch64";
    }
    .${pkgs.stdenv.hostPlatform.system};

  # Direct input names declared by spaces's flake.lock. Source of truth
  # for which inputs need an `--override-input spaces/<name>` at install
  # time. Read live so it stays in sync as spaces grows or drops inputs.
  spacesLock = builtins.fromJSON (builtins.readFile "${spacesSrc}/flake.lock");
  spacesDirectInputNames = builtins.attrNames spacesLock.nodes.root.inputs;

  # `{ name → outPath }` for every direct spaces input the outer flake
  # provides. Names absent from `inputs` are silently skipped — a missing
  # input surfaces at install time when the lock generator can't resolve
  # it, not at build time.
  inputOverrides = lib.genAttrs (builtins.filter (n: inputs ? ${n}) spacesDirectInputNames) (
    n: builtins.toString inputs.${n}.outPath
  );

in
{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
  ];

  # Replace upstream extensions package wherever it's referenced.
  nixpkgs.overlays = [
    (final: prev: {
      calamares-nixos-extensions = final.callPackage ../../packages/calamares-spaces-extensions {
        base = prev.calamares-nixos-extensions;
      };
    })
  ];

  # Spaces-flake path + per-input override map consumed by the patched
  # `main.py` at install time. Lives here (not substituted into the
  # extensions package) so the package stays independent of the spaces
  # flake source — otherwise any unrelated repo edit invalidates
  # calamares-nixos-extensions.
  environment.etc."calamares-spaces/install.json".text = builtins.toJSON {
    spacesFlake = toString spacesSrc;
    inherit inputOverrides;
  };

  # Trade ISO size for build speed: upstream defaults to
  # `zstd -Xcompression-level 19` which takes minutes to recompress
  # whenever any flake source byte changes. Level 5 cuts squashfs
  # build time by ~5x at the cost of a moderately larger image —
  # acceptable since this is a per-machine install medium, not a
  # download artifact.
  isoImage.squashfsCompression = "zstd -Xcompression-level 3";

  # Brand the install medium as Spaces OS: the output filename
  # (`spaces-os.iso`) and the ISO9660 volume label shown when the medium
  # is mounted. mkForce overrides the upstream calamares-gnome profile,
  # which sets both. volumeID caps at 32 chars.
  image.baseName = lib.mkForce "spaces-os";
  isoImage.volumeID = lib.mkForce "SPACES_OS";

  # Renames the boot-menu entries and the live ISO's os-release from
  # "NixOS" to "Spaces OS". Installed systems are branded by
  # nixosModules.spaces instead.
  system.nixos.distroName = "Spaces OS";

  # Re-packaged nixos-grub2-theme, so the boot-menu header logo can be
  # swapped later; for now it's the upstream theme unchanged.
  isoImage.grubTheme = pkgs.callPackage ../../packages/spaces-grub-theme { };

  # Pre-stage everything `nix-build` + `nixos-install` will touch:
  #
  #   - spacesSrc itself (referenced by `path:<store>` in default.nix);
  #   - the toplevel closure of a representative installed system, so
  #     `nixos-install --system <toplevel>` substitutes from the local
  #     store rather than refetching;
  #   - upstream nixpkgs source, so post-install `nixos-rebuild` also
  #     evaluates offline;
  #   - every flake input outPath.  When nix-build evaluates the spaces
  #     flake via `builtins.getFlake "path:..."`, it reads flake.lock
  #     and fetchTree's each input.  fetchTree resolves locally if the
  #     source path with the matching narHash is in the store; the
  #     evaluated input outPath has that same narHash.  Without these
  #     entries, every install hits the network for blueprint,
  #     etc.
  isoImage.storeContents = [
    spacesSrc
    flake.nixosConfigurations.${installerTargetFor}.config.system.build.toplevel
  ];
}
