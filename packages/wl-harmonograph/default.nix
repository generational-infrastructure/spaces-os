# wl-harmonograph: pinpox' animated harmonograph layer-shell wallpaper,
# the default Spaces session background (modules/nixos/harmonograph.nix).
# Not in nixpkgs; the source comes from the pinned `wl-harmonograph`
# flake input (see flake.nix), built here with our nixpkgs.
#
# Vendoring note: crates.io's `/api/v1/crates/.../download` endpoint now
# 403s the bare User-Agent that the flake-pinned nixpkgs' cargo-vendor
# fetcher sends (anti-scrape / rate-limit), which breaks the default
# vendoring FOD in egress-filtered build sandboxes. We rebuild that
# fetcher's helper verbatim from nixpkgs with the crate download URL
# repointed at the static.crates.io CDN — the host newer nixpkgs already
# switched to, which serves the identical tarballs with no UA gating. The
# vendored content (and thus upstream's cargoHash, which keys the staging
# FOD) is unchanged, so this stays reproducible and is a no-op where
# egress is unfiltered.
{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;

  # SRI hash of the vendored crate set — upstream's verified value
  # (github:pinpox/wl-harmonograph flake.nix). Repointing the download
  # host does not change the downloaded content, so this still validates.
  cargoHash = "sha256-jvCq3NQBIoK0ZctDeTeFi9eXIi7mbZYDF6RoiWCk7JY=";

  rustSupport = "${pkgs.path}/pkgs/build-support/rust";

  # The fetcher helper, verbatim from the flake-pinned nixpkgs except for
  # the crate download host (crates.io/api → static.crates.io CDN).
  fetchCargoVendorUtil =
    pkgs.writers.writePython3Bin "fetch-cargo-vendor-util"
      {
        libraries =
          with pkgs.python3Packages;
          [
            requests
            tomli-w
          ]
          ++ requests.optional-dependencies.socks;
        flakeIgnore = [ "E501" ];
      }
      (
        builtins.replaceStrings
          [ "https://crates.io/api/v1/crates/" ]
          [ "https://static.crates.io/crates/" ]
          (builtins.readFile "${rustSupport}/fetch-cargo-vendor-util.py")
      );

  replaceWorkspaceValues = pkgs.writers.writePython3Bin "replace-workspace-values" {
    libraries = with pkgs.python3Packages; [
      tomli
      tomli-w
    ];
    flakeIgnore = [
      "E501"
      "W503"
    ];
  } (builtins.readFile "${rustSupport}/replace-workspace-values.py");

  # The network-facing FOD: downloads + arranges the crate tarballs. Its
  # output hash is the cargoHash (mirrors nixpkgs' fetch-cargo-vendor.nix).
  vendorStaging = pkgs.stdenvNoCC.mkDerivation {
    name = "wl-harmonograph-vendor-staging";
    src = inputs.wl-harmonograph;
    impureEnvVars = lib.fetchers.proxyImpureEnvVars;
    nativeBuildInputs = [
      fetchCargoVendorUtil
      pkgs.cacert
      (pkgs.nix-prefetch-git.override {
        git = pkgs.gitMinimal;
        git-lfs = null;
      })
    ];
    buildPhase = ''
      runHook preBuild
      fetch-cargo-vendor-util create-vendor-staging ./Cargo.lock "$out"
      runHook postBuild
    '';
    strictDeps = true;
    dontConfigure = true;
    dontInstall = true;
    dontFixup = true;
    outputHash = cargoHash;
    outputHashAlgo = null;
    outputHashMode = "recursive";
  };

  # Rearrange the staging into the vendor dir cargoSetupHook expects
  # (no network).
  cargoDeps = pkgs.runCommand "wl-harmonograph-vendor" {
    inherit vendorStaging;
    nativeBuildInputs = [
      fetchCargoVendorUtil
      pkgs.cargo
      replaceWorkspaceValues
    ];
  } "fetch-cargo-vendor-util create-vendor \"$vendorStaging\" \"$out\"";
in
pkgs.rustPlatform.buildRustPackage {
  pname = "wl-harmonograph";
  # Match upstream's date-derived version (flake.nix: substring of
  # lastModifiedDate); falls back to the epoch if the input lacks it.
  version = builtins.substring 0 8 (inputs.wl-harmonograph.lastModifiedDate or "19700101");

  src = inputs.wl-harmonograph;

  inherit cargoDeps;

  nativeBuildInputs = [ pkgs.pkg-config ];

  buildInputs = with pkgs; [
    wayland
    libGL
    libglvnd
  ];

  # khronos-egl links EGL statically but still needs the GL driver at
  # runtime; mirror upstream's rpath fixup.
  postFixup = ''
    patchelf --add-rpath ${
      pkgs.lib.makeLibraryPath [
        pkgs.libglvnd
        pkgs.mesa
      ]
    } $out/bin/wl-harmonograph
  '';

  meta = {
    description = "Animated harmonograph wallpaper for Sway/Wayland";
    homepage = "https://github.com/pinpox/wl-harmonograph";
    license = pkgs.lib.licenses.mit;
    platforms = pkgs.lib.platforms.linux;
    mainProgram = "wl-harmonograph";
  };
}
