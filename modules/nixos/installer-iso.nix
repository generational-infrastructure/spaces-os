# Distro graphical installer ISO.
#
# Imports the upstream NixOS Calamares-GNOME live image and:
#   - shadows `calamares-nixos-extensions` via a nixpkgs overlay so
#     all upstream references resolve to our fork
#     (`calamares-distro-extensions`), which drops `packagechooser`
#     and emits a flake-based install referencing the distro flake
#     by its /nix/store path;
#   - bakes that store path into the patched `main.py` at
#     extensions-package build time via the `distroFlake` arg;
#   - pre-stages the distro flake source + a representative installed
#     system closure into the ISO's nix store so `nixos-install`
#     resolves everything offline.
#
# The live env is upstream GNOME; the *installed* env is niri (set
# by `nixosModules.distro` pulled in via the generated flake). That
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
  inherit (flake.lib) distroSrc;

  # Pre-stage the installed-system closure that matches the live
  # medium's arch. Keep this map in sync with the `installer-<arch>`
  # host dirs.
  installerTargetFor =
    {
      "x86_64-linux" = "installer-target";
      "aarch64-linux" = "installer-target-aarch64";
    }
    .${pkgs.stdenv.hostPlatform.system};

  # Direct input names declared by distro's flake.lock. Source of truth
  # for which inputs need an `--override-input distro/<name>` at install
  # time. Read live so it stays in sync as distro grows or drops inputs.
  distroLock = builtins.fromJSON (builtins.readFile "${distroSrc}/flake.lock");
  distroDirectInputNames = builtins.attrNames distroLock.nodes.root.inputs;

  # `{ name → outPath }` for every direct distro input the outer flake
  # provides. Names absent from `inputs` are silently skipped — a missing
  # input surfaces at install time when the lock generator can't resolve
  # it, not at build time.
  inputOverrides = lib.genAttrs (builtins.filter (n: inputs ? ${n}) distroDirectInputNames) (
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
      calamares-nixos-extensions = final.callPackage ../../packages/calamares-distro-extensions {
        base = prev.calamares-nixos-extensions;
      };
    })
  ];

  # Distro-flake path + per-input override map consumed by the patched
  # `main.py` at install time. Lives here (not substituted into the
  # extensions package) so the package stays independent of the distro
  # flake source — otherwise any unrelated repo edit invalidates
  # calamares-nixos-extensions.
  environment.etc."calamares-distro/install.json".text = builtins.toJSON {
    distroFlake = toString distroSrc;
    inherit inputOverrides;
  };

  # Trade ISO size for build speed: upstream defaults to
  # `zstd -Xcompression-level 19` which takes minutes to recompress
  # whenever any flake source byte changes. Level 5 cuts squashfs
  # build time by ~5x at the cost of a moderately larger image —
  # acceptable since this is a per-machine install medium, not a
  # download artifact.
  isoImage.squashfsCompression = "zstd -Xcompression-level 3";

  # Pre-stage everything `nix-build` + `nixos-install` will touch:
  #
  #   - distroSrc itself (referenced by `path:<store>` in default.nix);
  #   - the toplevel closure of a representative installed system, so
  #     `nixos-install --system <toplevel>` substitutes from the local
  #     store rather than refetching;
  #   - upstream nixpkgs source, so post-install `nixos-rebuild` also
  #     evaluates offline;
  #   - every flake input outPath.  When nix-build evaluates the distro
  #     flake via `builtins.getFlake "path:..."`, it reads flake.lock
  #     and fetchTree's each input.  fetchTree resolves locally if the
  #     source path with the matching narHash is in the store; the
  #     evaluated input outPath has that same narHash.  Without these
  #     entries, every install hits the network for blueprint,
  #     noctalia-shell, etc.
  isoImage.storeContents = [
    distroSrc
    flake.nixosConfigurations.${installerTargetFor}.config.system.build.toplevel
  ];
}
