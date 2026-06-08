# Spaces fork of upstream `calamares-nixos-extensions`.
#
# We reuse the upstream derivation untouched and only replace files:
#   - config/settings.conf        - drop the `packagechooser` step
#   - config/modules/welcome.conf  - drop internet requirement (offline)
#   - modules/nixos/main.py        - emit a wrapper flake whose inputs are
#                                    locked to pre-staged store paths so
#                                    the install resolves offline.
#
# Files live under ./files/ and are copied over the upstream tree in
# postPatch. A patch-file approach was rejected: the upstream main.py is
# 900+ lines and our rewrite touches most of it, which makes diff-based
# maintenance more fragile than wholesale replacement.
#
# `base` is overridable so the nixpkgs overlay in `installer-iso.nix`
# can shadow `calamares-nixos-extensions` with this fork without hitting
# infinite recursion (passes `prev.calamares-nixos-extensions`).
#
# The runtime spaces-flake path + per-input override map used to be
# substituted into `main.py` at this layer, which made the package
# rebuild whenever any unrelated repo file changed. Both values now
# come from `/etc/calamares-spaces/install.json` (or
# `$CALAMARES_SPACES_CONFIG`), staged by the consumer (installer-iso
# module / VM tests). Keeps this derivation independent of the spaces
# flake source path.
{
  pkgs,
  base ? pkgs.calamares-nixos-extensions,
  spaces-logos ? pkgs.callPackage ../spaces-logos { },
  ...
}:
let
  inherit (pkgs) lib;
in
base.overrideAttrs (old: {
  pname = "calamares-spaces-extensions";
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    pkgs.librsvg
    pkgs.graphicsmagick
  ];
  postPatch = (old.postPatch or "") + ''
    cp -f ${lib.cleanSource ./files/settings.conf} config/settings.conf
    cp -f ${lib.cleanSource ./files/welcome.conf} config/modules/welcome.conf
    cp -f ${lib.cleanSource ./files/main.py}       modules/nixos/main.py

    # Spaces OS Calamares branding: fork the upstream `nixos` branding dir
    # (reusing its artwork/slideshow) and override branding.desc to rename
    # the product to "Spaces OS". settings.conf selects it via `branding:`.
    cp -r branding/nixos branding/spaces-os
    cp -f ${lib.cleanSource ./files/branding/spaces-os/branding.desc}   branding/spaces-os/branding.desc
    # Spaces OS welcome-page styling: a branding stylesheet.qss (Geist font,
    # white content area, light sidebar, muted/coral welcome buttons).
    # Calamares auto-loads stylesheet.qss from the branding dir.
    cp -f ${lib.cleanSource ./files/branding/spaces-os/stylesheet.qss} branding/spaces-os/stylesheet.qss

    # Spaces OS welcome-page copy. The welcome heading and body are two
    # translatable strings in Calamares' welcome `Config` (no branding field
    # exists for them); a branding translation catalog replaces them for the
    # English locale. See the .ts header for the load-order reasoning. Compile
    # it with lrelease to branding/spaces-os/lang/calamares-spaces-os_en.qm,
    # the exact path BrandingLoader (Retranslator.cpp) expects:
    # <brandingDir>/lang/calamares-<componentName>_<locale>.qm.
    mkdir -p branding/spaces-os/lang
    cp -f ${lib.cleanSource ./files/branding/spaces-os/lang/calamares-spaces-os_en.ts} \
      branding/spaces-os/lang/calamares-spaces-os_en.ts
    ${pkgs.qt6.qttools}/bin/lrelease \
      branding/spaces-os/lang/calamares-spaces-os_en.ts \
      -qm branding/spaces-os/lang/calamares-spaces-os_en.qm
    # Real Spaces OS marks come from the shared `spaces-logos` fetchgit FOD.
    # The black mark is the window icon (productIcon).
    cp -f ${spaces-logos}/spaces-logo.svg branding/spaces-os/spaces-logo.svg
    # Welcome-page hero illustration (productWelcome): the pre-rendered
    # iridescent knot with the mockup's dashed grid + coral accents baked in.
    cp -f ${spaces-logos}/spaces-hero.png branding/spaces-os/spaces-hero.png

    # Custom QML sidebar (branding.desc `sidebar: qml`) and its wordmark header.
    cp -f ${lib.cleanSource ./files/branding/spaces-os/calamares-sidebar.qml} \
      branding/spaces-os/calamares-sidebar.qml

    # Sidebar header image (productLogo, consumed by calamares-sidebar.qml): the
    # SPACES wordmark (bird + wordmark, "OS" trimmed). The QML sidebar lays it
    # out at its true ~5:1 aspect, so -- unlike the old widget sidebar's square
    # slot -- no square-canvas padding is needed; just rasterise the SVG. 420px
    # wide keeps it crisp above the ~140px on-screen width at HiDPI scaling.
    rsvg-convert -w 420 ${spaces-logos}/spaces-logo-wordmark-spaces.svg \
      -o branding/spaces-os/sidebar-wordmark.png
  '';
})
